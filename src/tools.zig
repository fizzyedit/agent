//! What each request does, on the UI thread. A tool either answers in the frame it is taken, or
//! waits — for a snapshot to be taken, a tape to play out, fizzy to settle, a measurement to run —
//! and is answered from a later frame (`frame` checks what waits).
//!
//! Every tool's arguments and result are ZON. The bridge (`bridge/main.zig`) turns an MCP
//! client's JSON into these arguments; the results go back as text, which reads as it is.
//!
//! | tool | arguments | result |
//! |---|---|---|
//! | `hello` | `.{ .token }` | the tools, and what fizzy offers |
//! | `commands.list` | — | every command: id, title, enabled, parameters (kind, description, default) |
//! | `commands.call` | `.{ .id, .args = "<ZON>" }` | its result, or why not |
//! | `ui.snapshot` | — | what is on screen (`automation` service): role, name, tag, rect, parent |
//! | `ui.settled` | `.{ .timeout_ms }` | once nothing is in flight, or the time is up |
//! | `ui.act` | `.{ .steps, .snapshot, .timeout_ms }` | input played as a person's, then (by default) the screen |
//! | `tape.play` / `tape.outcome` | a live tape / `.{ .ticket }` | a ticket / how it ended |
//! | `profile.report` | `.{ .ms }` | the profiler's report after `ms` of frames: per plugin, per scope |
const std = @import("std");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const core = @import("core");
const Script = @import("tape").Script;
const Server = @import("Server.zig");

const Automation = sdk.services.automation.Api;

/// Requests waiting on something, answered from a later frame. UI thread only.
var waiting: std.ArrayListUnmanaged(Waiting) = .empty;

const Waiting = struct {
    req: *Server.Request,
    until: union(enum) {
        snapshot: Automation.SnapshotTicket,
        settled: i96,
        act: struct { tape: Automation.Ticket, deadline: i96, snapshot: bool },
        act_snapshot: struct { outcome: []u8, shot: Automation.SnapshotTicket },
        profile: i96,
    },
};

fn now() i96 {
    return std.Io.Clock.boot.now(dvui.io).nanoseconds;
}

fn ms(n: u32) i96 {
    return @as(i96, n) * std.time.ns_per_ms;
}

/// Take what arrived and answer what can be. Once a frame, from `beginFrame`.
pub fn frame(host: *sdk.Host, server: *Server) void {
    var batch: std.ArrayListUnmanaged(*Server.Request) = .empty;
    defer batch.deinit(host.allocator);
    server.take(&batch);
    for (batch.items) |req| handle(host, server, req);

    var i: usize = 0;
    while (i < waiting.items.len) {
        if (check(host, server, &waiting.items[i])) {
            _ = waiting.swapRemove(i);
        } else i += 1;
    }
}

/// Answer whatever still waits: fizzy is going.
pub fn deinit(host: *sdk.Host, server: *Server) void {
    for (waiting.items) |w| {
        switch (w.until) {
            .act_snapshot => |a| host.allocator.free(a.outcome),
            else => {},
        }
        w.req.answer(server, false, "fizzy is closing");
    }
    waiting.deinit(host.allocator);
}

fn automation(host: *sdk.Host) ?*Automation {
    return host.getServiceTyped(Automation);
}

fn handle(host: *sdk.Host, server: *Server, req: *Server.Request) void {
    var arena_state: std.heap.ArenaAllocator = .init(host.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = arena.dupeZ(u8, req.args) catch return req.answer(server, false, "out of memory");
    const tool = req.tool;

    if (eql(tool, "hello")) return req.answer(server, true,
        \\.{ .app = "fizzy", .tools = .{ "commands.list", "commands.call", "ui.snapshot", "ui.settled", "ui.act", "tape.play", "tape.outcome", "profile.report" } }
    );
    if (eql(tool, "commands.list")) return listCommands(host, server, req, arena);
    if (eql(tool, "commands.call")) {
        const a = parse(struct { id: []const u8, args: []const u8 = "" }, arena, source) orelse
            return req.answer(server, false, "commands.call takes .{ .id, .args = \"<ZON>\" }");
        return switch (host.callCommand(a.id, a.args, arena)) {
            .ok => |r| req.answer(server, true, r orelse "null"),
            .unknown => req.answer(server, false, "no command by that id (commands.list)"),
            .disabled => req.answer(server, false, "that command is not enabled now"),
            .bad_args => |m| req.answer(server, false, m),
            .failed => |m| req.answer(server, false, m),
        };
    }
    const auto = automation(host) orelse return req.answer(server, false, "this app offers no automation service");
    if (eql(tool, "ui.snapshot")) {
        return wait(host, server, req, .{ .snapshot = auto.snapshot() });
    }
    if (eql(tool, "ui.settled")) {
        const Args = struct { timeout_ms: u32 = 5000 };
        const a = parse(Args, arena, source) orelse Args{};
        if (auto.settled()) return req.answer(server, true, "true");
        return wait(host, server, req, .{ .settled = now() + ms(a.timeout_ms) });
    }
    if (eql(tool, "ui.act")) return act(host, server, req, auto, arena, source);
    if (eql(tool, "tape.play")) {
        return switch (auto.play(req.args)) {
            .started => |t| req.answer(server, true, std.fmt.allocPrint(arena, ".{{ .ticket = {d} }}", .{@intFromEnum(t)}) catch "?"),
            .busy => req.answer(server, false, "something else is driving fizzy: a tape or a demo"),
            .invalid => |why| req.answer(server, false, why),
        };
    }
    if (eql(tool, "tape.outcome")) {
        const a = parse(struct { ticket: u32 }, arena, source) orelse return req.answer(server, false, "tape.outcome takes .{ .ticket }");
        var buf: [64]u8 = undefined;
        return req.answer(server, true, outcomeText(&buf, auto.outcome(@enumFromInt(a.ticket))));
    }
    if (eql(tool, "profile.report")) {
        const Args = struct { ms: u32 = 1000 };
        const a = parse(Args, arena, source) orelse Args{};
        // A window of averages is half a second: ask for a little more than was asked.
        core.profile.want(a.ms + 600);
        return wait(host, server, req, .{ .profile = now() + ms(a.ms + 600) });
    }
    req.answer(server, false, "no such tool (hello lists them)");
}

fn wait(host: *sdk.Host, server: *Server, req: *Server.Request, until: @FieldType(Waiting, "until")) void {
    waiting.append(host.allocator, .{ .req = req, .until = until }) catch req.answer(server, false, "out of memory");
}

/// Not yet: look again next frame, and make sure there is one. What `w` waits on is written at
/// the end of a frame (a snapshot) or decided by one (a tape's last op), and this runs at the
/// start of the next, which an idle app would never draw.
fn later(host: *sdk.Host) bool {
    host.refresh();
    return false;
}

/// True once `w` is answered.
fn check(host: *sdk.Host, server: *Server, w: *Waiting) bool {
    const auto = automation(host) orelse {
        w.req.answer(server, false, "the automation service went away");
        return true;
    };
    switch (w.until) {
        .snapshot => |t| {
            const text = auto.snapshotText(t) orelse return later(host);
            w.req.answer(server, true, text);
            return true;
        },
        .settled => |deadline| {
            if (auto.settled()) {
                w.req.answer(server, true, "true");
                return true;
            }
            if (now() < deadline) return false;
            w.req.answer(server, true, "false");
            return true;
        },
        .act => |a| {
            const o = auto.outcome(a.tape);
            if (o == .playing and now() < a.deadline) return later(host);
            var buf: [64]u8 = undefined;
            const text = if (o == .playing) blk: {
                auto.stop(a.tape);
                break :blk ".took_longer_than_timeout_ms";
            } else outcomeText(&buf, o);
            if (!a.snapshot) {
                w.req.answer(server, true, text);
                return true;
            }
            // Then the screen, as it was left.
            const owned = host.allocator.dupe(u8, text) catch {
                w.req.answer(server, true, text);
                return true;
            };
            w.until = .{ .act_snapshot = .{ .outcome = owned, .shot = auto.snapshot() } };
            return later(host);
        },
        .act_snapshot => |a| {
            const screen = auto.snapshotText(a.shot) orelse return later(host);
            defer host.allocator.free(a.outcome);
            var out: std.Io.Writer.Allocating = .init(host.allocator);
            defer out.deinit();
            out.writer.print(".{{ .outcome = {s}, .screen = ", .{a.outcome}) catch {};
            out.writer.writeAll(screen) catch {};
            out.writer.writeAll("}\n") catch {};
            w.req.answer(server, true, out.written());
            return true;
        },
        .profile => |until| {
            // Frames to measure: ask for them, as the profiler window's "Continuous" does.
            if (now() < until) return later(host);
            const p = core.profile.current() orelse {
                w.req.answer(server, false, "no profiler in this app");
                return true;
            };
            var out: std.Io.Writer.Allocating = .init(host.allocator);
            defer out.deinit();
            core.profile.report(p, &out.writer, .{}) catch {};
            w.req.answer(server, true, out.written());
            return true;
        },
    }
}

/// `ui.act`'s steps, played as a live tape: a person's input, through the same widgets.
const Step = union(enum) {
    /// A tagged widget (`.tag`), or a point in the window in physical pixels (`.x`, `.y`, as a
    /// snapshot's rects are).
    click: Point,
    double_click: Point,
    move: Point,
    type: []const u8,
    /// A chord as the keymap spells it: "mod+s", "escape", "cmd+k cmd+s".
    key: []const u8,
    /// Hold until the tagged widget is drawn.
    wait_for: []const u8,
    /// Run a command with no arguments, as its menu row would (`commands.call` takes arguments).
    command: []const u8,
};

const Point = struct {
    tag: []const u8 = "",
    x: ?f32 = null,
    y: ?f32 = null,
};

fn act(host: *sdk.Host, server: *Server, req: *Server.Request, auto: *Automation, arena: std.mem.Allocator, source: [:0]const u8) void {
    const Args = struct { steps: []const Step, snapshot: bool = true, timeout_ms: u32 = 10_000 };
    const a = parse(Args, arena, source) orelse return req.answer(server, false,
        \\ui.act takes .{ .steps = .{ .{ .click = .{ .tag = "..." } }, .{ .type = "..." }, .{ .key = "mod+s" }, ... }, .snapshot = true }
    );
    var s: Script = .init(arena, "agent", "");
    s.check.live = true;
    // Quicker than a demo's person, still slow enough to watch: the pointer is seen to travel.
    s.pace = .{ .move_ms = 300, .hover_ms = 80, .click_ms = 60, .beat_ms = 150, .cps = 60 };
    const win = dvui.windowRectPixels();
    for (a.steps) |step| {
        const ok = switch (step) {
            .click => |p| s.click(target(p, win), .{}),
            .double_click => |p| s.click(target(p, win), .{ .double = true }),
            .move => |p| s.moveTo(target(p, win), .{}),
            .type => |t| s.typeText(t, .{}),
            .key => |k| s.key(k),
            .wait_for => |tag| s.waitFor(tag, .{}),
            .command => |id| s.command(id),
        };
        ok catch |err| return req.answer(server, false, @errorName(err));
    }
    // The script's memory is the request's arena: nothing to free here.
    const owned = s.finish() catch |err| return req.answer(server, false, @errorName(err));
    var bytes: std.Io.Writer.Allocating = .init(arena);
    owned.tape.write(&bytes.writer) catch return req.answer(server, false, "could not write the tape");
    switch (auto.play(bytes.written())) {
        .started => |t| wait(host, server, req, .{ .act = .{ .tape = t, .deadline = now() + ms(a.timeout_ms), .snapshot = a.snapshot } }),
        .busy => req.answer(server, false, "something else is driving fizzy: a tape or a demo"),
        .invalid => |why| req.answer(server, false, why),
    }
}

fn target(p: Point, win: dvui.Rect.Physical) @import("tape").Tape.Target {
    if (p.tag.len > 0) return .{ .tag = p.tag };
    return .{ .x = (p.x orelse 0) / @max(win.w, 1), .y = (p.y orelse 0) / @max(win.h, 1) };
}

fn outcomeText(buf: []u8, o: Automation.Outcome) []const u8 {
    return switch (o) {
        .playing => ".playing",
        .finished => ".finished",
        .unknown => ".unknown",
        .interrupted => |n| std.fmt.bufPrint(buf, ".{{ .interrupted_before_step = {d} }}", .{n}) catch "?",
        .timed_out => |n| std.fmt.bufPrint(buf, ".{{ .wait_timed_out_at_step = {d} }}", .{n}) catch "?",
        .stopped => |n| std.fmt.bufPrint(buf, ".{{ .stopped_before_step = {d} }}", .{n}) catch "?",
    };
}

fn listCommands(host: *sdk.Host, server: *Server, req: *Server.Request, arena: std.mem.Allocator) void {
    const ParamOut = struct {
        key: []const u8,
        label: []const u8,
        description: []const u8,
        kind: []const u8,
        required: bool,
        default: ?[]const u8 = null,
        choices: ?[]const []const u8 = null,
        min: ?f64 = null,
        max: ?f64 = null,
    };
    const CommandOut = struct {
        id: []const u8,
        title: []const u8,
        enabled: bool,
        params: []const ParamOut,
    };
    var out: std.ArrayListUnmanaged(CommandOut) = .empty;
    for (0..host.commandCount()) |i| {
        const c = host.commandAt(i) orelse continue;
        var params: std.ArrayListUnmanaged(ParamOut) = .empty;
        for (c.params) |p| {
            var po: ParamOut = .{ .key = p.key, .label = p.label, .description = p.description, .kind = @tagName(p.kind), .required = p.required, .default = p.default };
            switch (p.kind) {
                .enumeration => |e| po.choices = e.choices,
                .int => |k| {
                    po.min = @floatFromInt(k.min);
                    po.max = @floatFromInt(k.max);
                },
                .float => |k| {
                    po.min = k.min;
                    po.max = k.max;
                },
                else => {},
            }
            params.append(arena, po) catch {};
        }
        out.append(arena, .{ .id = c.id, .title = c.title, .enabled = host.commandEnabled(c.id), .params = params.items }) catch {};
    }
    var w: std.Io.Writer.Allocating = .init(arena);
    std.zon.stringify.serialize(out.items, .{ .emit_default_optional_fields = false }, &w.writer) catch {};
    req.answer(server, true, w.written());
}

fn parse(comptime T: type, arena: std.mem.Allocator, source: [:0]const u8) ?T {
    if (source.len == 0) return std.zon.parse.fromSliceAlloc(T, arena, ".{}", null, .{}) catch null;
    return std.zon.parse.fromSliceAlloc(T, arena, source, null, .{ .ignore_unknown_fields = true }) catch null;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
