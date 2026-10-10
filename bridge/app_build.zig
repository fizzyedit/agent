//! `fizzy_build` on an app's own repo: fizzy's, or an app built on fizzy. A plugin hot-reloads
//! inside the running fizzy, so its build loop lives in the plugin (`src/Build.zig`). The app
//! cannot reload itself: it restarts into its rebuilt executable (`app/watch/ExecutableWatcher.zig`,
//! Settings > Restart when rebuilt), keeping every open document, and everything inside it,
//! the agent plugin included, goes with the old process. So this half runs here, in the bridge,
//! which outlives the restart (plans/RESTART_AND_CRASHES_PLAN.md, step 5).
//!
//! One call: `zig build` in the repo, the compiler's errors as file, line and message; then, when
//! the build replaced the executable fizzy runs from, the restart: the old fizzy gone (its
//! connection breaks) and the new one answering (a new token in `connection.zon`); then the check,
//! a `fizzy_run` script, on the new build.
const std = @import("std");
const Io = std.Io;
const json = std.json;
const parseDiagnostic = @import("diagnostics").parse;
const Bridge = @import("main.zig").Bridge;

/// How long a fizzy that should restart may go on answering before the build says it did not:
/// the watcher waits 150 ms for the file to hold still, and the quit takes a frame or two.
const restart_grace_ms = 5_000;

pub const Args = struct {
    path: []const u8,
    optimize: []const u8 = "",
    check: ?json.Value = null,
    timeout_ms: u32 = 120_000,
};

/// Whether `path` is an app's repo rather than a plugin's: a plugin's has its identity file.
pub fn isApp(io: Io, path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const zon = std.fmt.bufPrint(&buf, "{s}/plugin.zig.zon", .{path}) catch return false;
    Io.Dir.cwd().access(io, zon, .{}) catch return true;
    return false;
}

pub fn run(b: *Bridge, arena: std.mem.Allocator, args: Args) Bridge.Answer {
    const io = b.io;
    if (!std.fs.path.isAbsolute(args.path)) return .{ .err = "fizzy_build needs the repo's directory, absolute" };
    const started = now(io);
    const deadline = started + @as(i96, args.timeout_ms) * std.time.ns_per_ms;
    var report: Io.Writer.Allocating = .init(arena);
    const w = &report.writer;

    // fizzy as it is before the build: what it runs from, and the token it answers to. Absent
    // when it is not running; the build still runs.
    const executable = b.executable(arena);
    const exe_before = if (executable) |e| stamp(io, e) else null;
    const token_before = b.connectionToken(arena);

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    argv.appendSlice(arena, &.{ "zig", "build" }) catch return .{ .err = "out of memory" };
    if (args.optimize.len > 0) argv.append(arena, std.fmt.allocPrint(arena, "-Doptimize={s}", .{args.optimize}) catch return .{ .err = "out of memory" }) catch {};
    const result = std.process.run(arena, io, .{
        .argv = argv.items,
        .cwd = .{ .path = args.path },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(16 << 20),
    }) catch |err| {
        w.print(".{{\n    .app = true,\n    .built = false,\n    .why = \"could not run zig build ({t}): is zig on PATH?\",\n}}\n", .{err}) catch {};
        return .{ .err = report.written() };
    };
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    w.print(".{{\n    .app = true,\n    .built = {},\n    .build_ms = {d:.0},\n", .{ ok, ms(started, now(io)) }) catch {};
    diagnostics(w, result.stderr, ok);
    if (!ok) return finish(w, &report);

    const exe = executable orelse {
        w.writeAll("    .restart = .not_running,\n    .why = \"fizzy was not running: start it, and the check runs on the next call\",\n") catch {};
        return finish(w, &report);
    };
    const exe_after = stamp(io, exe);
    if (exe_before != null and exe_after != null and exe_before.? == exe_after.?) {
        // Built, but not the executable fizzy runs from: nothing to restart into.
        w.writeAll("    .restart = .up_to_date,\n") catch {};
        return check(b, arena, w, &report, args);
    }

    // The restart: the old fizzy goes (a probe on its connection fails), the new one answers to a
    // new token.
    const built_at = now(io);
    var stopped_at: ?i96 = null;
    while (true) {
        const t = now(io);
        if (stopped_at == null) {
            if (b.probe(arena)) {
                if (ms(built_at, t) > restart_grace_ms) {
                    w.print("    .restart = .not_restarted,\n    .why = \"fizzy is still running {s}'s old build: is Settings > Restart when rebuilt on?\",\n", .{std.fs.path.basename(exe)}) catch {};
                    return finish(w, &report);
                }
            } else stopped_at = t;
        }
        if (stopped_at != null) {
            const token = b.connectionToken(arena);
            if (token != null and (token_before == null or !std.mem.eql(u8, token.?, token_before.?))) {
                if (b.reconnect(arena)) {
                    w.print("    .restart = .{{ .stopped_ms = {d:.0}, .ready_ms = {d:.0} }},\n", .{ ms(built_at, stopped_at.?), ms(built_at, now(io)) }) catch {};
                    break;
                }
            }
        }
        if (t > deadline) {
            if (stopped_at == null) {
                w.writeAll("    .restart = .timed_out,\n") catch {};
            } else {
                // Gone and not back: it most likely crashed starting the new build. Its crash
                // report is the seam (plans/RESTART_AND_CRASHES_PLAN.md, step 3).
                w.print("    .restart = .{{ .stopped_ms = {d:.0}, .came_back = false }},\n    .why = \"fizzy quit for the new build and did not come back: it may have crashed starting it\",\n", .{ms(built_at, stopped_at.?)}) catch {};
            }
            return finish(w, &report);
        }
        io.sleep(.fromMilliseconds(50), .awake) catch {};
    }
    return check(b, arena, w, &report, args);
}

/// The check, as `fizzy_run` runs it, on the fizzy now answering.
fn check(b: *Bridge, arena: std.mem.Allocator, w: *Io.Writer, report: *Io.Writer.Allocating, args: Args) Bridge.Answer {
    const steps = args.check orelse return finish(w, report);
    var run_args: json.ObjectMap = .empty;
    run_args.put(arena, "steps", steps) catch return .{ .err = "out of memory" };
    run_args.put(arena, "timeout_ms", .{ .integer = 10_000 }) catch {};
    const zon = switch (b.toolArgs(arena, Bridge.runTool(), .{ .object = run_args })) {
        .ok => |s| s,
        .err => |e| return .{ .err = e },
    };
    const answer = b.call(arena, "ui.run", zon);
    const text = switch (answer) {
        .ok => |s| s,
        .err => |s| s,
    };
    w.writeAll("    .check = ") catch {};
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) w.writeAll("\n    ") catch {};
        w.writeAll(line) catch {};
        first = false;
    }
    w.writeAll(",\n") catch {};
    return finish(w, report);
}

fn finish(w: *Io.Writer, report: *Io.Writer.Allocating) Bridge.Answer {
    w.writeAll("}\n") catch {};
    return .{ .ok = report.written() };
}

/// The compiler's errors, each `file:line:column: kind: message` line as data; or, for a failure
/// that is not a compile error, the tail of what zig said.
fn diagnostics(w: *Io.Writer, output: []const u8, ok: bool) void {
    var any = false;
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |raw| {
        const d = parseDiagnostic(std.mem.trimEnd(u8, raw, "\r")) orelse continue;
        if (!any) w.writeAll("    .errors = .{\n") catch {};
        any = true;
        w.print("        .{{ .file = \"{s}\", .line = {d}, .column = {d}, .kind = .{s}, .message = ", .{ d.file, d.line, d.column, d.kind }) catch {};
        std.zon.stringify.serialize(d.message, .{}, w) catch {};
        w.writeAll(" },\n") catch {};
    }
    if (any) {
        w.writeAll("    },\n") catch {};
    } else if (!ok) {
        const tail = output[output.len - @min(output.len, 1500) ..];
        w.writeAll("    .output = ") catch {};
        std.zon.stringify.serialize(tail, .{}, w) catch {};
        w.writeAll(",\n") catch {};
    }
}

fn stamp(io: Io, path: []const u8) ?i96 {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    return st.mtime.nanoseconds;
}

fn now(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

fn ms(from: i96, to: i96) f64 {
    return @as(f64, @floatFromInt(to - from)) / std.time.ns_per_ms;
}
