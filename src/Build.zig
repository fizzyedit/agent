//! A plugin's whole edit loop in one call (`plugin.build`; plans/AGENTS_PLAN.md, "Closer to
//! native", step 2): build it, answer the compiler's errors as file, line and message, wait for
//! fizzy to reload the rebuilt binary (the `plugins` service's generation moving), and run a check
//! script on what came back (`Run.zig`). Edit, build, look: one turn instead of three or four, and
//! since a reload keeps open documents, the person's work is undisturbed.
//!
//! The build runs on a thread of its own, `zig build` in the plugin's directory with
//! `FIZZY_PROFILE` naming this fizzy's profile, so the plugin installs where this fizzy loads it
//! from. `zig` is found on PATH or the login shell's; the tools plan (TOOLS_AND_TRUST_PLAN) will
//! hand a managed one, and `core.darwin_spawn` an environment, in place of `/usr/bin/env`.
//!
//! Not for the agent plugin itself: its reload ends the request that asked for it.
const Build = @This();

const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const core = @import("core");
const Run = @import("Run.zig");
const parseDiagnostic = @import("diagnostics.zig").parse;

const Plugins = sdk.services.plugins.Api;
const Automation = sdk.services.automation.Api;

gpa: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
/// The connection that asked: its check's `call` steps are that agent's (`Run.conn`).
conn: u32,
args: Args,
id: []const u8,
argv: []const []const u8,
/// What the build thread leaves, read once `done`.
thread: ?std.Thread = null,
done: std.atomic.Value(bool) = .init(false),
exit_code: ?u8 = null,
output: []u8 = &.{},
build_ms: f64 = 0,
spawn_failed: bool = false,
/// The plugin before the build: its loads and failed loads so far, and its installed binary's
/// stamp. A reload moves the first; one that fails, the second.
generation: u32,
failures: u32,
binary: []const u8,
binary_stamp: i128,
phase: union(enum) { building, reloading: i96, checking: *Run } = .building,
report: std.Io.Writer.Allocating,

pub const Args = struct {
    /// The plugin's directory (where its `build.zig` is), absolute.
    path: []const u8,
    /// `-Doptimize`, as zig spells it; empty for the plugin's default.
    optimize: []const u8 = "",
    /// Steps to run once it has reloaded (`ui.run`'s), checking what came back.
    check: []const Run.Step = &.{},
    timeout_ms: u32 = 120_000,
};

/// Start building the plugin `source` (ZON: `Args`) names. Errors say what was wrong with it.
pub fn start(gpa: std.mem.Allocator, host: *sdk.Host, plugins: *Plugins, conn: u32, source: [:0]const u8) !*Build {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const args = std.zon.parse.fromSliceAlloc(Args, a, source, null, .{ .ignore_unknown_fields = true }) catch return error.BadArguments;
    if (!std.fs.path.isAbsolute(args.path)) return error.PathNotAbsolute;

    // Which plugin: its identity file, as the build helper reads it.
    const zon_path = try std.fs.path.join(a, &.{ args.path, "plugin.zig.zon" });
    const zon = std.Io.Dir.cwd().readFileAllocOptions(dvui.io, zon_path, a, .limited(64 * 1024), .of(u8), 0) catch return error.NoPluginZon;
    const Identity = struct { id: []const u8 };
    const id = (std.zon.parse.fromSliceAlloc(Identity, a, zon, null, .{ .ignore_unknown_fields = true }) catch return error.NoPluginZon).id;
    if (std.mem.eql(u8, id, "agent")) return error.CannotBuildItself;

    const plugins_dir = host.plugins_dir orelse return error.NoPluginsDir;
    const profile = std.fs.path.dirname(plugins_dir) orelse plugins_dir;
    const ext = switch (builtin.os.tag) {
        .macos => "dylib",
        .windows => "dll",
        else => "so",
    };
    const binary = try std.fmt.allocPrint(a, "{s}/{s}/{s}.{s}", .{ plugins_dir, id, id, ext });

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "/usr/bin/env", try std.fmt.allocPrint(a, "FIZZY_PROFILE={s}", .{profile}), resolveZig(gpa, a) orelse "zig", "build" });
    if (args.optimize.len > 0) try argv.append(a, try std.fmt.allocPrint(a, "-Doptimize={s}", .{args.optimize}));

    const self = try gpa.create(Build);
    errdefer gpa.destroy(self);
    self.* = .{
        .gpa = gpa,
        .conn = conn,
        .arena = arena,
        .args = args,
        .id = id,
        .argv = argv.items,
        .generation = plugins.status(id).generation,
        .failures = plugins.status(id).failures,
        .binary = binary,
        .binary_stamp = stamp(binary),
        .report = .init(gpa),
    };
    self.thread = try std.Thread.spawn(.{}, build, .{self});
    return self;
}

pub fn deinit(self: *Build) void {
    if (self.thread) |t| t.join();
    switch (self.phase) {
        .checking => |r| r.deinit(self.gpa),
        else => {},
    }
    self.gpa.free(self.output);
    self.report.deinit();
    self.arena.deinit();
    self.gpa.destroy(self);
}

fn stamp(path: []const u8) i128 {
    const st = std.Io.Dir.cwd().statFile(dvui.io, path, .{}) catch return 0;
    return st.mtime.nanoseconds;
}

fn now() i96 {
    return std.Io.Clock.boot.now(dvui.io).nanoseconds;
}

/// The build thread: run it, keep everything it printed, and how it ended.
fn build(self: *Build) void {
    defer self.done.store(true, .release);
    const started = now();
    var child = spawn(self.gpa, self.argv, self.args.path) catch {
        self.spawn_failed = true;
        return;
    };
    // zig prints its errors and progress to stderr; read it all, then reap.
    var out: std.Io.Writer.Allocating = .init(self.gpa);
    if (child.stderr) |stderr| {
        var buf: [4096]u8 = undefined;
        var r = stderr.readerStreaming(dvui.io, &buf);
        _ = r.interface.streamRemaining(&out.writer) catch {};
    }
    const term = child.wait(dvui.io) catch {
        self.spawn_failed = true;
        out.deinit();
        return;
    };
    self.exit_code = switch (term) {
        .exited => |code| code,
        else => 255,
    };
    self.output = out.toOwnedSlice() catch &.{};
    self.build_ms = @as(f64, @floatFromInt(now() - started)) / std.time.ns_per_ms;
}

fn spawn(gpa: std.mem.Allocator, argv: []const []const u8, cwd: []const u8) !std.process.Child {
    if (comptime builtin.os.tag == .macos) {
        return core.darwin_spawn.spawn(gpa, .{ .argv = argv, .cwd = cwd, .stdin = .discard, .stdout = .discard, .stderr = .pipe }, core.shell_env.path(gpa, dvui.io));
    }
    return std.process.spawn(dvui.io, .{ .argv = argv, .cwd = .{ .path = cwd }, .stdin = .ignore, .stdout = .ignore, .stderr = .pipe, .create_no_window = true });
}

/// `zig` on this process's PATH, then the login shell's, as a path allocated with `a`.
/// `core.shell_env.path` caches what it resolves in memory from the allocator it is first given,
/// so it gets the long-lived `gpa`, never the build's arena.
fn resolveZig(gpa: std.mem.Allocator, a: std.mem.Allocator) ?[]const u8 {
    const inherited: ?[]const u8 = if (std.c.getenv("PATH")) |p| std.mem.span(p) else null;
    for ([_]?[]const u8{ inherited, core.shell_env.path(gpa, dvui.io) }) |path_value| {
        var it = std.mem.splitScalar(u8, path_value orelse continue, ':');
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            const candidate = std.fs.path.join(a, &.{ dir, "zig" }) catch continue;
            std.Io.Dir.accessAbsolute(dvui.io, candidate, .{ .execute = true }) catch continue;
            return candidate;
        }
    }
    return null;
}

/// Go as far as this frame allows; the finished report once done (owned by the build).
pub fn advance(self: *Build, host: *sdk.Host, plugins: *Plugins, auto: ?*Automation) ?[]const u8 {
    const w = &self.report.writer;
    switch (self.phase) {
        .building => {
            if (!self.done.load(.acquire)) return null;
            self.thread.?.join();
            self.thread = null;
            w.print(".{{\n    .plugin = \"{s}\",\n", .{self.id}) catch {};
            if (self.spawn_failed) {
                w.writeAll("    .built = false,\n    .why = \"could not run zig build: is zig installed, and on your shell's PATH?\",\n}\n") catch {};
                return self.report.written();
            }
            w.print("    .built = {},\n    .build_ms = {d:.0},\n", .{ self.exit_code == 0, self.build_ms }) catch {};
            self.diagnostics(w);
            if (self.exit_code != 0) {
                w.writeAll("}\n") catch {};
                return self.report.written();
            }
            if (stamp(self.binary) == self.binary_stamp) {
                // zig built nothing new: no binary changed, so fizzy has nothing to reload.
                w.writeAll("    .reload = .up_to_date,\n") catch {};
                return self.checkOrFinish(host, auto);
            }
            self.phase = .{ .reloading = now() + @as(i96, self.args.timeout_ms) * std.time.ns_per_ms };
            host.refresh();
            return null;
        },
        .reloading => |deadline| {
            const st = plugins.status(self.id);
            if (st.generation != self.generation) {
                w.print("    .reload = .{{ .generation = {d}, .opened_ms = {d:.1}, .swapped_ms = {d:.1} }},\n", .{ st.generation, st.opened_ms, st.swapped_ms }) catch {};
                return self.checkOrFinish(host, auto);
            }
            if (st.failures != self.failures) {
                w.writeAll("    .reload = .{ .failed = ") catch {};
                std.zon.stringify.serialize(st.why, .{}, w) catch {};
                w.writeAll(" },\n}\n") catch {};
                return self.report.written();
            }
            if (now() > deadline) {
                w.writeAll("    .reload = .timed_out,\n}\n") catch {};
                return self.report.written();
            }
            host.refresh();
            return null;
        },
        .checking => |r| return self.finishCheck(r.advance(host, auto.?) orelse return null),
    }
}

fn finishCheck(self: *Build, report: []const u8) []const u8 {
    const w = &self.report.writer;
    w.writeAll("    .check = ") catch {};
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, report, "\n"), '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) w.writeAll("\n    ") catch {};
        w.writeAll(line) catch {};
        first = false;
    }
    w.writeAll(",\n}\n") catch {};
    return self.report.written();
}

fn checkOrFinish(self: *Build, host: *sdk.Host, auto: ?*Automation) ?[]const u8 {
    const w = &self.report.writer;
    if (self.args.check.len == 0 or auto == null) {
        w.writeAll("}\n") catch {};
        return self.report.written();
    }
    var src: std.Io.Writer.Allocating = .init(self.arena.allocator());
    // `Run.Step` nests (a `compare` holds steps), so the serializer is given a depth to stop at.
    std.zon.stringify.serializeMaxDepth(Run.Args{ .steps = self.args.check }, .{ .emit_default_optional_fields = false }, &src.writer, 32) catch return self.fail("could not write the check");
    const zon = self.arena.allocator().dupeZ(u8, src.written()) catch return self.fail("out of memory");
    const r = Run.init(self.gpa, self.conn, zon) catch return self.fail("the check is not a script ui.run takes");
    self.phase = .{ .checking = r };
    const report = r.advance(host, auto.?) orelse return null;
    return self.finishCheck(report);
}

fn fail(self: *Build, why: []const u8) []const u8 {
    self.report.writer.print("    .why = \"{s}\",\n}}\n", .{why}) catch {};
    return self.report.written();
}

/// The compiler's errors, as `file:line:column: error: message` lines become, each with the notes
/// that follow it.
fn diagnostics(self: *Build, w: *std.Io.Writer) void {
    var any = false;
    var it = std.mem.splitScalar(u8, self.output, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const d = parseDiagnostic(line) orelse continue;
        if (!any) w.writeAll("    .errors = .{\n") catch {};
        any = true;
        w.print("        .{{ .file = \"{s}\", .line = {d}, .column = {d}, .kind = .{s}, .message = ", .{ d.file, d.line, d.column, d.kind }) catch {};
        std.zon.stringify.serialize(d.message, .{}, w) catch {};
        w.writeAll(" },\n") catch {};
    }
    if (any) {
        w.writeAll("    },\n") catch {};
    } else if (self.exit_code != 0) {
        // Not a compile error (a missing dependency, a failed fetch): the tail of what zig said.
        const tail = self.output[self.output.len - @min(self.output.len, 1500) ..];
        w.writeAll("    .output = ") catch {};
        std.zon.stringify.serialize(tail, .{}, w) catch {};
        w.writeAll(",\n") catch {};
    }
}
