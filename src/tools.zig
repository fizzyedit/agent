//! What each request does, on the UI thread. A tool either answers in the frame it is taken, or
//! waits — for a snapshot to be taken, a tape to play out, fizzy to settle, a measurement to run —
//! and is answered from a later frame (`frame` checks what waits).
//!
//! Every tool's arguments and result are ZON. The bridge (`bridge/main.zig`) turns an MCP
//! client's JSON into these arguments; the results go back as text, which reads as it is.
//!
//! | tool | arguments | result |
//! |---|---|---|
//! | `hello` | `.{ .token }` | the tools, what fizzy offers, and the executable it runs from |
//! | `commands.list` | — | every command: id, title, enabled, parameters (kind, description, default) |
//! | `commands.call` | `.{ .id, .args = "<ZON>" }` | its result, or why not |
//! | `ui.snapshot` | — | what is on screen (`automation` service): fizzy's windows, then each widget's role, name, tag, rect, parent and window |
//! | `ui.capture` | `.{ .path, .window }` | a picture of a window (the main one, one by its tag, or `"*"` for all), as fizzy drew it, written raw to `path` (`"FZPX"`, width and height as little-endian `u32`, then premultiplied RGBA rows: the bridge scales and encodes it); on screen or not |
//! | `ui.settled` | `.{ .timeout_ms }` | once nothing is in flight, or the time is up |
//! | `ui.act` | `.{ .steps, .snapshot, .timeout_ms }` | input played as a person's, then (by default) the screen |
//! | `tape.play` / `tape.outcome` | a live tape / `.{ .ticket }` | a ticket / how it ended |
//! | `profile.report` | `.{ .ms }` | the profiler's report after `ms` of frames: per plugin, per scope |
//! | `doc.claim` | `.{ .path, .label }` | a claim on an open document (`sdk.Claim`): the person's input to it waits until `doc.release`, the connection closes, or they press Stop |
//! | `doc.release` | `.{ .claim }` | `.{ .tape }` when the session was recorded (`Recording`), else null |
const std = @import("std");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const core = @import("core");
const Server = @import("Server.zig");
const Run = @import("Run.zig");
const measure = @import("measure.zig");
const Build = @import("Build.zig");
const Recording = @import("Recording.zig");

const Automation = sdk.services.automation.Api;

/// Requests waiting on something, answered from a later frame. UI thread only.
var waiting: std.ArrayListUnmanaged(Waiting) = .empty;

const Waiting = struct {
    req: *Server.Request,
    until: union(enum) {
        snapshot: Automation.SnapshotTicket,
        /// A picture, written to `path` (the host's allocation) once taken.
        capture: struct { ticket: Automation.CaptureTicket, path: []u8 },
        settled: i96,
        run: *Run,
        build: *Build,
        profile: struct { until: i96, drive: bool, startup: bool = false },
    },
};

fn now() i96 {
    return std.Io.Clock.boot.now(dvui.io).nanoseconds;
}

fn ms(n: u32) i96 {
    return @as(i96, n) * std.time.ns_per_ms;
}

/// The agent plugin itself, which claims documents (`doc.claim`). Set by `plugin.zig`.
pub var owner: ?*sdk.Plugin = null;

/// Documents claimed for a connection. UI thread only.
var held: std.ArrayListUnmanaged(Held) = .empty;
const Held = struct {
    claim: u32,
    conn: u32,
    path: []u8,
    /// The session on it so far, written as a tape when the claim ends.
    rec: ?Recording = null,
};

/// What a connection should hear with its next answer: a claim the person stopped.
var notices: std.ArrayListUnmanaged(struct { conn: u32, text: []u8 }) = .empty;

/// Take what arrived and answer what can be. Once a frame, from `beginFrame`.
pub fn frame(host: *sdk.Host, server: *Server) void {
    var batch: std.ArrayListUnmanaged(*Server.Request) = .empty;
    defer batch.deinit(host.allocator);
    var closed: std.ArrayListUnmanaged(u32) = .empty;
    defer closed.deinit(host.allocator);
    server.take(&batch, &closed);
    tendClaims(host, server, closed.items);
    for (batch.items) |req| {
        attachNotice(server, req);
        handle(host, server, req);
    }

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
            .run => |r| r.deinit(host.allocator),
            .build => |b| b.deinit(),
            else => {},
        }
        w.req.answer(server, false, "fizzy is closing");
    }
    waiting.deinit(host.allocator);
    for (held.items) |*h| {
        host.releaseClaim(h.claim);
        if (finish(host, h)) |tape| host.allocator.free(tape);
        host.allocator.free(h.path);
    }
    held.deinit(host.allocator);
    for (notices.items) |n| server.gpa.free(n.text);
    notices.deinit(host.allocator);
}

/// Let go of what closed connections held, and turn claims the person stopped into a notice for
/// the connection that made them.
fn tendClaims(host: *sdk.Host, server: *Server, closed: []const u32) void {
    var i: usize = 0;
    while (i < held.items.len) {
        const h = &held.items[i];
        const gone = std.mem.indexOfScalar(u32, closed, h.conn) != null;
        if (gone) {
            host.releaseClaim(h.claim);
            if (finish(host, h)) |tape| {
                std.log.info("agent: the session on {s} is a tape: {s}", .{ h.path, tape });
                host.allocator.free(tape);
            }
        } else if (!host.claimHolds(h.claim)) {
            const tape = finish(host, h);
            defer if (tape) |t| host.allocator.free(t);
            const text = std.fmt.allocPrint(server.gpa, "the person pressed Stop on {s}: leave it be, and ask before claiming it again.{s}{s}", .{ h.path, if (tape != null) " The session so far is a tape: " else "", tape orelse "" }) catch null;
            if (text) |t| notices.append(host.allocator, .{ .conn = h.conn, .text = t }) catch server.gpa.free(t);
        } else {
            i += 1;
            continue;
        }
        host.allocator.free(h.path);
        _ = held.swapRemove(i);
    }
}

fn attachNotice(server: *Server, req: *Server.Request) void {
    for (notices.items, 0..) |n, i| {
        if (n.conn != req.conn) continue;
        if (req.notice) |old| server.gpa.free(old);
        req.notice = n.text;
        _ = notices.swapRemove(i);
        return;
    }
}

fn claim(host: *sdk.Host, server: *Server, req: *Server.Request, arena: std.mem.Allocator, source: [:0]const u8) void {
    const a = parse(struct { path: []const u8, label: []const u8 = "An agent" }, arena, source) orelse
        return req.answer(server, false, "doc.claim takes .{ .path, .label }");
    const me = owner orelse return req.answer(server, false, "the agent plugin is not registered");
    const doc = host.docFromPath(a.path) orelse return req.answer(server, false, "that document is not open: open it first (fizzy.openFiles)");
    const id = host.claimDocument(me, doc.id, a.label) catch |err| return req.answer(server, false, switch (err) {
        error.DocumentClaimed => "someone else is working on that document",
        else => "out of memory",
    });
    for (held.items) |h| {
        if (h.claim == id) return req.answer(server, true, std.fmt.allocPrint(arena, ".{{ .claim = {d} }}", .{id}) catch "?");
    }
    const path = host.allocator.dupe(u8, a.path) catch return req.answer(server, false, "out of memory");
    const unix_s: i64 = @intCast(@divTrunc(std.Io.Clock.real.now(dvui.io).nanoseconds, std.time.ns_per_s));
    const rec = Recording.start(host.allocator, doc, a.path, a.label, unix_s) catch |err| blk: {
        std.log.info("agent: {s} is held but not recorded: {t}", .{ a.path, err });
        break :blk null;
    };
    held.append(host.allocator, .{ .claim = id, .conn = req.conn, .path = path, .rec = rec }) catch {
        host.allocator.free(path);
        host.releaseClaim(id);
        return req.answer(server, false, "out of memory");
    };
    req.answer(server, true, std.fmt.allocPrint(arena, ".{{ .claim = {d} }}", .{id}) catch "?");
}

fn release(host: *sdk.Host, server: *Server, req: *Server.Request, arena: std.mem.Allocator, source: [:0]const u8) void {
    const a = parse(struct { claim: u32 }, arena, source) orelse return req.answer(server, false, "doc.release takes .{ .claim }");
    for (held.items, 0..) |*h, i| {
        if (h.claim != a.claim) continue;
        host.releaseClaim(h.claim);
        const tape = finish(host, h);
        defer if (tape) |t| host.allocator.free(t);
        host.allocator.free(h.path);
        _ = held.swapRemove(i);
        if (tape) |t| return req.answer(server, true, std.fmt.allocPrint(arena, ".{{ .tape = \"{s}\" }}", .{t}) catch "null");
        break;
    }
    req.answer(server, true, "null");
}

/// Write a held document's session as a tape, if anything was recorded, into `<config>/tapes/`;
/// the recording is done either way. Returns the tape's path, in `host.allocator`.
fn finish(host: *sdk.Host, h: *Held) ?[]u8 {
    var rec = h.rec orelse return null;
    h.rec = null;
    defer rec.deinit();
    if (rec.empty()) return null;
    const plugins = host.plugins_dir orelse return null;
    const config = std.fs.path.dirname(plugins) orelse return null;
    const dir = std.fs.path.join(host.allocator, &.{ config, "tapes" }) catch return null;
    defer host.allocator.free(dir);
    return rec.write(dir, dvui.io) catch |err| {
        std.log.err("agent: could not write the tape for {s}: {t}", .{ h.path, err });
        return null;
    };
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

    if (eql(tool, "hello")) {
        // The executable this fizzy runs from: the bridge compares it across an app build to tell
        // whether fizzy will restart into a new one (`fizzy_build` on an app's repo).
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = std.process.executablePath(dvui.io, &buf) catch 0;
        var w: std.Io.Writer.Allocating = .init(arena);
        std.zon.stringify.serialize(.{
            .app = "fizzy",
            .executable = buf[0..n],
            .tools = .{ "commands.list", "commands.call", "ui.snapshot", "ui.capture", "ui.settled", "ui.act", "ui.run", "plugin.build", "tape.play", "tape.outcome", "profile.report", "doc.claim", "doc.release" },
        }, .{ .whitespace = false }, &w.writer) catch return req.answer(server, false, "out of memory");
        return req.answer(server, true, w.written());
    }
    if (eql(tool, "commands.list")) return listCommands(host, server, req, arena);
    if (eql(tool, "doc.claim")) return claim(host, server, req, arena, source);
    if (eql(tool, "doc.release")) return release(host, server, req, arena, source);
    if (eql(tool, "commands.call")) {
        const a = parse(struct { id: []const u8, args: []const u8 = "" }, arena, source) orelse
            return req.answer(server, false, "commands.call takes .{ .id, .args = \"<ZON>\" }");
        return switch (host.callCommand(a.id, a.args, arena)) {
            .ok => |r| {
                for (held.items) |*h| {
                    if (h.conn != req.conn) continue;
                    if (h.rec) |*rec| rec.note(a.id, a.args, host.last_showing_ms) catch {};
                }
                req.answer(server, true, r orelse "null");
            },
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
    if (eql(tool, "ui.capture")) {
        const a = parse(struct { path: []const u8, window: []const u8 = "" }, arena, source) orelse
            return req.answer(server, false, "ui.capture takes .{ .path = \"<absolute path of the raw picture to write>\", .window = \"<a window's tag, or \\\"*\\\" for all; none for the main window>\" }");
        if (!std.fs.path.isAbsolute(a.path)) return req.answer(server, false, "give the picture's path as an absolute path");
        const path = host.allocator.dupe(u8, a.path) catch return req.answer(server, false, "out of memory");
        return wait(host, server, req, .{ .capture = .{ .ticket = auto.capture(a.window), .path = path } });
    }
    if (eql(tool, "ui.settled")) {
        const Args = struct { timeout_ms: u32 = 5000 };
        const a = parse(Args, arena, source) orelse Args{};
        if (auto.settled()) return req.answer(server, true, "true");
        return wait(host, server, req, .{ .settled = now() + ms(a.timeout_ms) });
    }
    if (eql(tool, "ui.act")) return act(host, server, req, arena, source);
    if (eql(tool, "ui.run")) return run(host, server, req, auto, source);
    if (eql(tool, "plugin.build")) {
        const plugins = host.getServiceTyped(sdk.services.plugins.Api) orelse return req.answer(server, false, "this app offers no plugins service (fizzy's SDK 0.2.22 or later)");
        const b = Build.start(host.allocator, host, plugins, source) catch |err| return req.answer(server, false, switch (err) {
            error.BadArguments => "plugin.build takes .{ .path = \"<plugin directory>\", .optimize, .check = .{ <ui.run steps> }, .timeout_ms }",
            error.PathNotAbsolute => "give the plugin's directory as an absolute path",
            error.NoPluginZon => "no plugin.zig.zon with an id in that directory",
            error.CannotBuildItself => "the agent plugin cannot rebuild itself: its reload would end this request",
            else => @errorName(err),
        });
        return wait(host, server, req, .{ .build = b });
    }
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
        // `drive`: ask for every frame, to measure what drawing costs; else only the frames fizzy
        // draws on its own are measured (`measure.zig`).
        // `startup`: also when the app's start reached each phase (`core.profile.Phases`).
        const Args = struct { ms: u32 = 1000, drive: bool = false, startup: bool = false };
        const a = parse(Args, arena, source) orelse Args{};
        // A window of averages is half a second: ask for a little more than was asked.
        core.profile.want(a.ms + 600);
        return wait(host, server, req, .{ .profile = .{ .until = now() + ms(a.ms + 600), .drive = a.drive, .startup = a.startup } });
    }
    req.answer(server, false, "no such tool (hello lists them)");
}

fn wait(host: *sdk.Host, server: *Server, req: *Server.Request, until: @FieldType(Waiting, "until")) void {
    waiting.append(host.allocator, .{ .req = req, .until = until }) catch req.answer(server, false, "out of memory");
}

/// `image` as the bridge reads it: `"FZPX"`, its width and height (little-endian `u32`s), then its
/// pixels as drawn. No encode: that is the bridge's, in its own process, not this frame's.
fn writeRaw(path: []const u8, image: Automation.Image) !void {
    const io = dvui.io;
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var head: [12]u8 = undefined;
    head[0..4].* = "FZPX".*;
    std.mem.writeInt(u32, head[4..8], image.width, .little);
    std.mem.writeInt(u32, head[8..12], image.height, .little);
    var buf: [64 * 1024]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.writeAll(&head);
    try w.interface.writeAll(image.pixels);
    try w.end();
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
        .capture => |c| {
            const image = auto.captureImage(c.ticket) orelse return later(host);
            defer host.allocator.free(c.path);
            if (image.width == 0) {
                w.req.answer(server, false, "no window has that tag: ui.snapshot lists them (.role = \"window\")");
                return true;
            }
            // Raw, as fizzy drew it: the bridge, in its own process, scales and encodes it.
            writeRaw(c.path, image) catch |err| {
                w.req.answer(server, false, @errorName(err));
                return true;
            };
            w.req.answer(server, true, c.path);
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
        .build => |b| {
            const plugins = host.getServiceTyped(sdk.services.plugins.Api) orelse {
                w.req.answer(server, false, "the plugins service went away");
                b.deinit();
                return true;
            };
            const report = b.advance(host, plugins, auto) orelse return false;
            w.req.answer(server, true, report);
            b.deinit();
            return true;
        },
        .run => |r| {
            const report = r.advance(host, auto) orelse return false;
            w.req.answer(server, true, report);
            r.deinit(host.allocator);
            return true;
        },
        .profile => |wait_p| {
            if (now() < wait_p.until) {
                // Driving, every frame, as the profiler window's "Continuous" does; else one frame
                // when the window ends, and whatever fizzy draws meanwhile.
                if (wait_p.drive) return later(host);
                measure.wakeAt(wait_p.until, now());
                return false;
            }
            const p = core.profile.current() orelse {
                w.req.answer(server, false, "no profiler in this app");
                return true;
            };
            var out: std.Io.Writer.Allocating = .init(host.allocator);
            defer out.deinit();
            core.profile.report(p, &out.writer, .{ .startup = wait_p.startup }) catch {};
            w.req.answer(server, true, out.written());
            return true;
        },
    }
}

/// `ui.run`: a script, run across frames, answered with one report (`Run.zig`).
fn run(host: *sdk.Host, server: *Server, req: *Server.Request, auto: *Automation, source: [:0]const u8) void {
    const r = Run.init(host.allocator, source) catch |err| return req.answer(server, false, switch (err) {
        error.BadScript => "ui.run takes .{ .steps = .{ .{ .click = .{ .tag = \"...\" } }, .{ .call = .{ .id, .args } }, .{ .expect = .{ .tag } }, .{ .settle = .{} }, .{ .screen = .{} }, .{ .profile = .{ .ms } }, ... }, .timeout_ms }",
        error.OutOfMemory => "out of memory",
    });
    if (r.advance(host, auto)) |report| {
        req.answer(server, true, report);
        return r.deinit(host.allocator);
    }
    wait(host, server, req, .{ .run = r });
}

/// `ui.act`: input as a live tape, then the screen unless `snapshot` is false. A run of its
/// steps, with `screen` after.
fn act(host: *sdk.Host, server: *Server, req: *Server.Request, arena: std.mem.Allocator, source: [:0]const u8) void {
    const Args = struct { steps: []const Run.Step, snapshot: bool = true, timeout_ms: u32 = 10_000 };
    const a = parse(Args, arena, source) orelse return req.answer(server, false,
        \\ui.act takes .{ .steps = .{ .{ .click = .{ .tag = "..." } }, .{ .type = "..." }, .{ .key = "mod+s" }, ... }, .snapshot = true }
    );
    var steps: std.ArrayListUnmanaged(Run.Step) = .empty;
    steps.appendSlice(arena, a.steps) catch return req.answer(server, false, "out of memory");
    if (a.snapshot) steps.append(arena, .{ .screen = .{} }) catch return req.answer(server, false, "out of memory");
    var out: std.Io.Writer.Allocating = .init(arena);
    // `Run.Step` nests (a `compare` holds steps): the serializer is given a depth to stop at.
    std.zon.stringify.serializeMaxDepth(Run.Args{ .steps = steps.items, .timeout_ms = a.timeout_ms }, .{ .emit_default_optional_fields = false }, &out.writer, 32) catch
        return req.answer(server, false, "out of memory");
    const zon = arena.dupeZ(u8, out.written()) catch return req.answer(server, false, "out of memory");
    const auto = automation(host) orelse return req.answer(server, false, "this app offers no automation service");
    run(host, server, req, auto, zon);
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
