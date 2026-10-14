//! Lets an AI agent drive fizzy the way a person does (fizzyedit/plans, `plans/AGENTS_PLAN.md`).
//!
//! A socket only this user can open (`src/Server.zig`) takes requests from `fizzy-mcp`, the MCP
//! bridge in this repo, and the plugin answers them on the UI thread, in `beginFrame`
//! (`src/tools.zig`): every command as a tool, with its parameters; the screen as text (the
//! `automation` service's snapshot); input as live tapes; the profiler on request. Nothing here is
//! a back door — commands are the ones plugins offer, and input goes through the same widgets a
//! person's does, so everything shows on screen and in undo, and a person's click stops it.
//!
//! Desktop only: a wasm side module cannot open a socket.
const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const Server = @import("src/Server.zig");
const tools = @import("src/tools.zig");

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
    try h.registerPlugin(&plugin);
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
    try server.?.start();
    std.log.info("agent: listening on {s}", .{socket_path});
}

/// `<plugins>/agent/connection.zon`: where the socket is, and the token a client says hello with.
/// Readable by this user only.
fn writeConnection(dir: []const u8, socket_path: []const u8, token: []const u8) !void {
    const path = try std.fmt.allocPrint(host.allocator, "{s}/connection.zon", .{dir});
    defer host.allocator.free(path);
    const file = try std.Io.Dir.cwd().createFile(dvui.io, path, .{ .permissions = .fromMode(0o600) });
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
    if (server) |*s| tools.frame(host, s);
}

fn deinit(_: *anyopaque) void {
    if (server) |*s| {
        tools.deinit(host, s);
        s.stop();
        host.allocator.free(s.socket_path);
    }
    server = null;
}
