//! Measuring fizzy without disturbing it, and comparing two measurements (`ui.run`'s `profile`
//! and `compare` steps, `profile.report`).
//!
//! A measurement used to ask for a frame every frame while it waited, which made an idle fizzy
//! draw at the display's rate and put every frame down to the agent (the profiler's frame causes
//! said so). Now waiting asks for one frame, when the window ends (`wakeAt`), and measures what
//! fizzy does on its own; `drive` asks for every frame instead, to measure what drawing costs.
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");

/// The timer that wakes fizzy when a measurement ends. One is enough: one measurement waits at a
/// time per frame, and the latest deadline wins.
const timer_id: dvui.Id = @fromBackingInt(@intCast(0x6167_6e74_6d65_6173)); // "agntmeas"

/// Ask for a frame at `until` (boot-clock nanoseconds), however idle fizzy is meanwhile. Called each
/// frame while waiting, which also keeps the timer alive (dvui drops one nobody asks after).
pub fn wakeAt(until: i96, now: i96) void {
    if (dvui.current_window == null) return;
    if (!dvui.timerDoneOrNone(timer_id)) return;
    const micros = @divFloor(@max(until - now, std.time.ns_per_ms), std.time.ns_per_us);
    dvui.timer(timer_id, @intCast(@min(micros, std.math.maxInt(i32))));
}

/// The profiler's last window, kept: the frame and each scope's own time.
pub const Snapshot = struct {
    fps: f64 = 0,
    work_ms: f64 = 0,
    worst_work_ms: f64 = 0,
    frames: u32 = 0,
    scopes: []Scope = &.{},

    pub const Scope = struct { owner: []const u8, name: []const u8, self_ms: f64 };

    /// Now, copied into `a`. Empty when there is no profiler.
    pub fn take(a: std.mem.Allocator) Snapshot {
        const p = core.profile.current() orelse return .{};
        const st = p.stats;
        const scopes = a.alloc(Scope, p.count) catch return .{};
        for (p.entries[0..p.count], scopes) |e, *s| s.* = .{
            .owner = a.dupe(u8, e.owner) catch "",
            .name = a.dupe(u8, e.name) catch "",
            .self_ms = e.avg_self_ns / std.time.ns_per_ms,
        };
        return .{
            .fps = st.fps,
            .work_ms = st.work_ns / std.time.ns_per_ms,
            .worst_work_ms = @as(f64, @floatFromInt(st.worst_work_ns)) / std.time.ns_per_ms,
            .frames = st.frames,
            .scopes = scopes,
        };
    }

    fn selfOf(self: Snapshot, owner: []const u8, name: []const u8) f64 {
        for (self.scopes) |s| if (std.mem.eql(u8, s.owner, owner) and std.mem.eql(u8, s.name, name)) return s.self_ms;
        return 0;
    }
};

/// Before and after, as ZON: the frame both times, and the scopes whose own time per frame moved
/// most (at most `top`, by how far), a scope only one side has counting as zero on the other.
pub fn writeCompare(w: *std.Io.Writer, a: std.mem.Allocator, before: Snapshot, after: Snapshot, top: usize, indent: []const u8) std.Io.Writer.Error!void {
    try w.print(".{{\n{s}    .before = .{{ .fps = {d:.1}, .work_ms = {d:.3}, .worst_work_ms = {d:.3}, .frames = {d} }},\n", .{ indent, before.fps, before.work_ms, before.worst_work_ms, before.frames });
    try w.print("{s}    .after = .{{ .fps = {d:.1}, .work_ms = {d:.3}, .worst_work_ms = {d:.3}, .frames = {d} }},\n", .{ indent, after.fps, after.work_ms, after.worst_work_ms, after.frames });
    const Moved = struct { owner: []const u8, name: []const u8, before_ms: f64, after_ms: f64 };
    var moved: std.ArrayListUnmanaged(Moved) = .empty;
    for (after.scopes) |s| moved.append(a, .{ .owner = s.owner, .name = s.name, .before_ms = before.selfOf(s.owner, s.name), .after_ms = s.self_ms }) catch {};
    for (before.scopes) |s| if (!has(after, s)) {
        moved.append(a, .{ .owner = s.owner, .name = s.name, .before_ms = s.self_ms, .after_ms = 0 }) catch {};
    };
    std.mem.sort(Moved, moved.items, {}, struct {
        fn more(_: void, x: Moved, y: Moved) bool {
            return @abs(x.after_ms - x.before_ms) > @abs(y.after_ms - y.before_ms);
        }
    }.more);
    try w.print("{s}    .moved = .{{\n", .{indent});
    for (moved.items[0..@min(top, moved.items.len)]) |m| {
        if (@abs(m.after_ms - m.before_ms) < 0.001) break;
        try w.print("{s}        .{{ .owner = \"{s}\", .scope = \"{s}\", .before_ms = {d:.3}, .after_ms = {d:.3} }},\n", .{ indent, m.owner, m.name, m.before_ms, m.after_ms });
    }
    try w.print("{s}    }},\n{s}}}", .{ indent, indent });
}

fn has(s: Snapshot, x: Snapshot.Scope) bool {
    for (s.scopes) |y| if (std.mem.eql(u8, y.owner, x.owner) and std.mem.eql(u8, y.name, x.name)) return true;
    return false;
}
