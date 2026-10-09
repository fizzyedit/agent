//! The agent plugin, and `fizzy-mcp`, the bridge an MCP client runs: `zig build` installs the
//! plugin into fizzy's plugins directory (or `FIZZY_PROFILE`'s) and the bridge into `zig-out/bin`.
const std = @import("std");
const fizzy = @import("fizzy");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const plugin = fizzy.plugin.create(b, .{ .target = target, .optimize = optimize });
    // `ui.act` writes its steps as a live tape (`tape.Script`): the SDK's own `tape`, the one its
    // `core` was built with, from the same dependency instance `create` used.
    const sdk = b.dependency("fizzy", .{ .target = target, .optimize = optimize, .plugin_sdk = true });
    plugin.module.addImport("tape", sdk.module("tape"));
    fizzy.plugin.install(b, plugin.lib, .{});

    // std-only: it relays between an MCP client on stdio and the plugin's socket.
    const bridge = b.addExecutable(.{
        .name = "fizzy-mcp",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("bridge/main.zig"),
        }),
    });
    b.installArtifact(bridge);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("bridge/main.zig"),
    }) });
    b.step("test", "Run the bridge's tests").dependOn(&b.addRunArtifact(tests).step);
}
