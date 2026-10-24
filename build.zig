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
    plugin.module.addImport("replay", sdk.module("replay"));
    fizzy.plugin.install(b, plugin.lib, .{});

    // std-only: it relays between an MCP client on stdio and the plugin's socket, and makes the
    // pictures (scaling and encoding a frame fizzy hands over raw), so it is always built
    // optimized: a tool, not code anyone steps through, and the encode is 10x slower in Debug.
    const bridge_optimize: std.builtin.OptimizeMode = if (optimize == .debug) .fast else optimize;
    // The compiler's diagnostics, read the same way by the plugin's build loop and the bridge's.
    const diagnostics_module = b.createModule(.{
        .target = target,
        .optimize = bridge_optimize,
        .root_source_file = b.path("src/diagnostics.zig"),
    });
    const bridge = b.addExecutable(.{
        .name = "fizzy-mcp",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = bridge_optimize,
            .root_source_file = b.path("bridge/main.zig"),
            .imports = &.{.{ .name = "diagnostics", .module = diagnostics_module }},
        }),
    });
    b.installArtifact(bridge);
    // Beside the plugin's library too, `<plugins>/agent/fizzy-mcp`, where the chat plugin looks
    // for it to hand an agent (ACP `session/new`'s `mcpServers`). Not on the web, which has no
    // plugins directory.
    if (target.result.cpu.arch != .wasm32) fizzy.plugin.installBeside(b, bridge, .{ .plugin = "agent" });

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("bridge/main.zig"),
        .imports = &.{.{ .name = "diagnostics", .module = diagnostics_module }},
    }) });
    const diagnostics = b.addTest(.{ .root_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/diagnostics.zig"),
    }) });
    const recording = b.addTest(.{ .root_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/Recording.zig"),
        .imports = &.{
            .{ .name = "fizzy_sdk", .module = sdk.module("fizzy_sdk") },
            .{ .name = "tape", .module = sdk.module("tape") },
        },
    }) });
    const test_step = b.step("test", "Run the tests: the bridge's, reading compiler diagnostics, and a session's tape");
    test_step.dependOn(&b.addRunArtifact(recording).step);
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(diagnostics).step);
}
