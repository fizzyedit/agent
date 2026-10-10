//! A script an agent sends in one call, run in fizzy's frames at frame rate, answered with one
//! report (`ui.run`; plans/AGENTS_PLAN.md, "Closer to native"). Turns, not milliseconds, are what
//! an agent's iteration costs: "open this, type that, wait until it settles, check it is there,
//! measure it, show me" is one turn instead of six.
//!
//! Steps run in order. Input and waits play as live tapes through the `automation` service, the
//! consecutive ones as one tape, so the person sees the pointer move and a click of theirs stops
//! it. The rest run here, between tapes: `call` a command with arguments (its result goes in the
//! report), `expect` a widget on screen or gone, `settle`, take the `screen`, `profile` for a
//! while. The first step that fails ends the run, and the report says which and why.
const Run = @This();

const std = @import("std");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const core = @import("core");
const Script = @import("tape").Script;
const Tape = @import("tape").Tape;

const Automation = sdk.services.automation.Api;

/// Owns the steps and every string they hold, for the run's life.
arena: std.heap.ArenaAllocator,
steps: []const Step,
/// How long a wait in a tape, or `settle`, holds before the run fails.
timeout_ms: u32,
/// The next step to start.
at: usize = 0,
/// What the step in progress waits on, between frames.
waiting: Waiting = .none,
report: std.Io.Writer.Allocating,
failed: ?usize = null,

pub const Step = union(enum) {
    /// A tagged widget, or a point in the window in physical pixels (as a snapshot's rects are).
    click: Point,
    double_click: Point,
    move: Point,
    type: []const u8,
    /// A chord as the keymap spells it: "mod+s", "escape".
    key: []const u8,
    /// Run a command with no arguments, as its menu row would.
    command: []const u8,
    /// Hold until the tagged widget is drawn, or gone; past `timeout_ms` the run fails.
    wait_for: []const u8,
    wait_gone: []const u8,
    /// Run a command with arguments (ZON) and keep its result.
    call: struct { id: []const u8, args: []const u8 = "" },
    /// The tagged widget is drawn now (`shown`, the default) or not: no waiting.
    expect: struct { tag: []const u8, shown: bool = true },
    /// Wait until nothing is in flight: no animation, load or tape.
    settle: struct {},
    /// What is on screen now, into the report.
    screen: struct {},
    /// Measure this many milliseconds of frames; the profiler's report goes in the report.
    profile: struct { ms: u32 = 1000 },

    fn isTape(self: Step) bool {
        return switch (self) {
            .click, .double_click, .move, .type, .key, .command, .wait_for, .wait_gone => true,
            else => false,
        };
    }
};

pub const Point = struct {
    tag: []const u8 = "",
    x: ?f32 = null,
    y: ?f32 = null,
};

const Waiting = union(enum) {
    none,
    tape: struct { ticket: Automation.Ticket, last: usize, deadline: i96 },
    settle: i96,
    screen: Automation.SnapshotTicket,
    profile: i96,
};

pub const Args = struct {
    steps: []const Step,
    timeout_ms: u32 = 10_000,
};

/// A run of `source` (ZON: `Args`), or why it cannot be one. The caller `deinit`s it.
pub fn init(gpa: std.mem.Allocator, source: [:0]const u8) error{ BadScript, OutOfMemory }!*Run {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const args = std.zon.parse.fromSliceAlloc(Args, arena.allocator(), source, null, .{ .ignore_unknown_fields = true }) catch
        return error.BadScript;
    const self = try gpa.create(Run);
    self.* = .{ .arena = arena, .steps = args.steps, .timeout_ms = args.timeout_ms, .report = .init(gpa) };
    self.report.writer.writeAll(".{\n    .steps = .{\n") catch return error.OutOfMemory;
    return self;
}

pub fn deinit(self: *Run, gpa: std.mem.Allocator) void {
    self.report.deinit();
    self.arena.deinit();
    gpa.destroy(self);
}

fn now() i96 {
    return std.Io.Clock.boot.now(dvui.io).nanoseconds;
}

fn ms(n: u32) i96 {
    return @as(i96, n) * std.time.ns_per_ms;
}

/// Go as far as this frame allows. The finished report (owned by the run) once done, else null:
/// call again next frame, which `host.refresh` makes sure there is.
pub fn advance(self: *Run, host: *sdk.Host, auto: *Automation) ?[]const u8 {
    while (true) {
        if (!self.poll(host, auto)) {
            host.refresh();
            return null;
        }
        if (self.failed != null or self.at >= self.steps.len) return self.finish();
        self.begin(host, auto);
    }
}

/// Settle what the step in progress waits on. False while it still waits.
fn poll(self: *Run, host: *sdk.Host, auto: *Automation) bool {
    const w = &self.report.writer;
    switch (self.waiting) {
        .none => return true,
        .tape => |t| {
            const o = auto.outcome(t.ticket);
            if (o == .playing and now() < t.deadline) return false;
            if (o == .playing) auto.stop(t.ticket);
            switch (o) {
                .finished => w.print("        .{{ .steps = .{{ {d}, {d} }}, .played = true }},\n", .{ self.at, t.last }) catch {},
                else => {
                    // The tape's ops are not the script's steps: say which step range, and why.
                    const why: []const u8 = switch (o) {
                        .interrupted => "a person's input stopped it",
                        .timed_out => "a wait gave up: what it waited for never came",
                        .playing => "it took longer than timeout_ms",
                        else => "it stopped",
                    };
                    w.print("        .{{ .steps = .{{ {d}, {d} }}, .played = false, .why = \"{s}\" }},\n", .{ self.at, t.last, why }) catch {};
                    self.failed = self.at;
                },
            }
            self.at = t.last + 1;
        },
        .settle => |deadline| {
            if (!auto.settled()) {
                if (now() < deadline) return false;
                w.print("        .{{ .step = {d}, .settled = false }},\n", .{self.at}) catch {};
                self.failed = self.at;
            } else w.print("        .{{ .step = {d}, .settled = true }},\n", .{self.at}) catch {};
            self.at += 1;
        },
        .screen => |ticket| {
            const text = auto.snapshotText(ticket) orelse return false;
            w.print("        .{{ .step = {d}, .screen = ", .{self.at}) catch {};
            indented(w, text);
            w.writeAll(" },\n") catch {};
            self.at += 1;
        },
        .profile => |until| {
            if (now() < until) return false;
            w.print("        .{{ .step = {d}, .profile = ", .{self.at}) catch {};
            if (core.profile.current()) |p| {
                var out: std.Io.Writer.Allocating = .init(self.arena.allocator());
                core.profile.report(p, &out.writer, .{}) catch {};
                indented(w, out.written());
            } else w.writeAll("null") catch {};
            w.writeAll(" },\n") catch {};
            self.at += 1;
        },
    }
    self.waiting = .none;
    _ = host;
    return true;
}

/// Start step `at`: a run of tape steps, or one of the rest.
fn begin(self: *Run, host: *sdk.Host, auto: *Automation) void {
    const w = &self.report.writer;
    const step = self.steps[self.at];
    if (step.isTape()) {
        var last = self.at;
        while (last + 1 < self.steps.len and self.steps[last + 1].isTape()) last += 1;
        const ticket = self.playTape(auto, self.steps[self.at .. last + 1]) catch |err| {
            w.print("        .{{ .steps = .{{ {d}, {d} }}, .played = false, .why = \"{t}\" }},\n", .{ self.at, last, err }) catch {};
            self.failed = self.at;
            return;
        };
        // Each wait in it holds up to `timeout_ms`; the whole tape, a little longer than all of them.
        const deadline = now() + ms(self.timeout_ms) * @as(i96, @intCast(last - self.at + 2));
        self.waiting = .{ .tape = .{ .ticket = ticket, .last = last, .deadline = deadline } };
        return;
    }
    switch (step) {
        .call => |c| {
            const out = host.callCommand(c.id, c.args, self.arena.allocator());
            switch (out) {
                .ok => |r| {
                    w.print("        .{{ .step = {d}, .call = \"{s}\", .result = ", .{ self.at, c.id }) catch {};
                    indented(w, r orelse "null");
                    w.writeAll(" },\n") catch {};
                },
                else => {
                    const why: []const u8 = switch (out) {
                        .unknown => "no command by that id",
                        .disabled => "that command is not enabled now",
                        .bad_args, .failed => |m| m,
                        .ok => unreachable,
                    };
                    w.print("        .{{ .step = {d}, .call = \"{s}\", .failed = ", .{ self.at, c.id }) catch {};
                    std.zon.stringify.serialize(why, .{}, w) catch {};
                    w.writeAll(" },\n") catch {};
                    self.failed = self.at;
                },
            }
            self.at += 1;
        },
        .expect => |e| {
            const shown = if (dvui.tagGet(e.tag)) |td| td.visible else false;
            const holds = shown == e.shown;
            w.print("        .{{ .step = {d}, .expect = \"{s}\", .shown = {}, .holds = {} }},\n", .{ self.at, e.tag, shown, holds }) catch {};
            if (!holds) self.failed = self.at;
            self.at += 1;
        },
        .settle => self.waiting = .{ .settle = now() + ms(self.timeout_ms) },
        .screen => self.waiting = .{ .screen = auto.snapshot() },
        .profile => |p| {
            // A window of averages is half a second: a little more than asked.
            core.profile.want(p.ms + 600);
            self.waiting = .{ .profile = now() + ms(p.ms + 600) };
        },
        else => unreachable,
    }
}

/// Steps as one live tape, played now. Quick enough to watch: the pointer is seen to travel.
fn playTape(self: *Run, auto: *Automation, steps: []const Step) !Automation.Ticket {
    const arena = self.arena.allocator();
    var s: Script = .init(arena, "agent", "");
    s.check.live = true;
    s.pace = .{ .move_ms = 300, .hover_ms = 80, .click_ms = 60, .beat_ms = 150, .cps = 60 };
    const win = dvui.windowRectPixels();
    const wait: Script.WaitOptions = .{ .timeout = self.timeout_ms };
    for (steps) |step| switch (step) {
        .click => |p| try s.click(target(p, win), .{}),
        .double_click => |p| try s.click(target(p, win), .{ .double = true }),
        .move => |p| try s.moveTo(target(p, win), .{}),
        .type => |t| try s.typeText(t, .{}),
        .key => |k| try s.key(k),
        .command => |id| try s.command(id),
        .wait_for => |tag| try s.waitFor(tag, wait),
        .wait_gone => |tag| try s.waitGone(tag, wait),
        else => unreachable,
    };
    const owned = try s.finish();
    var bytes: std.Io.Writer.Allocating = .init(arena);
    try owned.tape.write(&bytes.writer);
    return switch (auto.play(bytes.written())) {
        .started => |t| t,
        .busy => error.SomethingElseIsDrivingFizzy,
        .invalid => error.NotALiveTape,
    };
}

fn target(p: Point, win: dvui.Rect.Physical) Tape.Target {
    if (p.tag.len > 0) return .{ .tag = p.tag };
    return .{ .x = (p.x orelse 0) / @max(win.w, 1), .y = (p.y orelse 0) / @max(win.h, 1) };
}

fn finish(self: *Run) []const u8 {
    const w = &self.report.writer;
    w.writeAll("    },\n") catch {};
    if (self.failed) |f| {
        w.print("    .ok = false,\n    .failed_at = {d},\n}}\n", .{f}) catch {};
    } else w.writeAll("    .ok = true,\n}\n") catch {};
    return self.report.written();
}

/// `text` (ZON, maybe several lines) written as a nested value: its lines indented to sit inside
/// the report.
fn indented(w: *std.Io.Writer, text: []const u8) void {
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) w.writeAll("\n        ") catch {};
        w.writeAll(line) catch {};
        first = false;
    }
}
