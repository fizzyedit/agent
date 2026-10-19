//! Lets an AI agent drive fizzy the way a person does (fizzyedit/plans, `plans/AGENTS_PLAN.md`).
//!
//! Its tools are `agent.*` commands (`src/commands.zig`): scripts, input as live tapes, builds,
//! pictures, the profiler on request, holding a document. Fizzy's control server serves them as
//! it serves every command (`/mcp`), each call the caller's step. A socket only this user can open
//! (`src/Server.zig`) takes requests from `fizzy-mcp`, the MCP bridge in this repo, and routes
//! them to the same commands on the UI thread, in `beginFrame` (`src/tools.zig`). Nothing here is
//! a back door — commands are the ones plugins offer, and input goes through the same widgets a
//! person's does, so everything shows on screen and in undo, and a person's click stops it.
//!
//! The socket is desktop only: a wasm side module cannot open one. The commands are not.
const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const Server = @import("src/Server.zig");
const tools = @import("src/tools.zig");
const commands = @import("src/commands.zig");

pub const plugin_options = @import("fizzy_plugin_options");
pub const plugin_id = plugin_options.id;

var plugin: sdk.Plugin = .{
    .state = undefined,
    .vtable = &vtable,
    .id = plugin_id,
    .display_name = plugin_options.name,
};

const vtable: sdk.Plugin.VTable = .{
    .initPlugin = initPlugin,
    .beginFrame = beginFrame,
    .deinit = deinit,
};

var host: *sdk.Host = undefined;
var server: ?Server = null;
var state: u8 = 0;

pub fn register(h: *sdk.Host) !void {
    host = h;
    plugin.state = @ptrCast(&state);
    tools.owner = &plugin;
    tools.the_host = h;
    try h.registerPlugin(&plugin);
    try commands.register(h, &plugin);
}

fn initPlugin(_: *anyopaque) anyerror!void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    const gpa = host.allocator;
    const dir = host.pluginInstallDir(plugin_id) orelse return error.NoPluginsDir;
    defer gpa.free(dir);

    var token: [32]u8 = undefined;
    var raw: [16]u8 = undefined;
    dvui.io.random(&raw);
    _ = std.fmt.bufPrint(&token, "{x}", .{&raw}) catch unreachable;

    // A Unix socket's path is limited (104 bytes on macOS): a deep profile falls back to the temp
    // directory, and `connection.zon` says where either way.
    const beside = try std.fmt.allocPrint(gpa, "{s}/agent.sock", .{dir});
    const socket_path = if (beside.len < 100) beside else blk: {
        gpa.free(beside);
        // Windows has no `/tmp`, and its process ids are not `pid_t`s.
        if (comptime builtin.target.os.tag == .windows) {
            const temp = if (std.c.getenv("TEMP")) |t| std.mem.span(t) else return error.NoTempDir;
            break :blk try std.fmt.allocPrint(gpa, "{s}\\fizzy-agent-{d}.sock", .{ temp, std.os.windows.GetCurrentProcessId() });
        }
        break :blk try std.fmt.allocPrint(gpa, "/tmp/fizzy-agent-{d}.sock", .{std.c.getpid()});
    };
    server = .{
        .gpa = gpa,
        .io = dvui.io,
        .socket_path = socket_path,
        .token = token,
        .wake = wake,
    };
    try writeConnection(dir, socket_path, &token);
    tools.the_server = &server.?;
    try server.?.start();
    std.log.info("agent: listening on {s}", .{socket_path});
}

/// `<plugins>/agent/connection.zon`: where the socket is, and the token a client says hello with.
/// Readable by this user only: by its mode, or on Windows by the profile directory's own ACL, which a
/// new file inherits.
fn writeConnection(dir: []const u8, socket_path: []const u8, token: []const u8) !void {
    const path = try std.fmt.allocPrint(host.allocator, "{s}/connection.zon", .{dir});
    defer host.allocator.free(path);
    const permissions: std.Io.File.Permissions = if (comptime builtin.target.os.tag == .windows) .default_file else .fromMode(0o600);
    const file = try std.Io.Dir.cwd().createFile(dvui.io, path, .{ .permissions = permissions });
    defer file.close(dvui.io);
    var buf: [1024]u8 = undefined;
    var w = file.writer(dvui.io, &buf);
    try std.zon.stringify.serialize(.{ .socket = socket_path, .token = token }, .{}, &w.interface);
    try w.interface.flush();
}

fn wake() void {
    host.refresh();
}

fn beginFrame(_: *anyopaque) void {
    tools.frame(host);
}

fn deinit(_: *anyopaque) void {
    tools.deinit(host);
    if (server) |*s| {
        s.stop();
        host.allocator.free(s.socket_path);
    }
    tools.the_server = null;
    server = null;
}
