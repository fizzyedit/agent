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

    // std-only: it relays between an MCP client on stdio and the plugin's socket.
    // The compiler's diagnostics, read the same way by the plugin's build loop and the bridge's.
    const diagnostics_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/diagnostics.zig"),
    });
    const bridge = b.addExecutable(.{
        .name = "fizzy-mcp",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("bridge/main.zig"),
            .imports = &.{.{ .name = "diagnostics", .module = diagnostics_module }},
        }),
    });
    b.installArtifact(bridge);
    // Beside the plugin's library too, `<plugins>/agent/fizzy-mcp`, where the chat plugin looks
    // for it to hand an agent (ACP `session/new`'s `mcpServers`). Not on the web, which has no
    // plugins directory.
    if (target.result.cpu.arch != .wasm32) {
        const beside = b.allocator.create(BesidePlugin) catch @panic("OOM");
        beside.* = .{
            .step = std.Build.Step.init(.{ .id = .custom, .name = "install fizzy-mcp beside the plugin", .owner = b, .makeFn = BesidePlugin.make }),
            .exe = bridge,
        };
        beside.step.dependOn(&bridge.step);
        b.getInstallStep().dependOn(&beside.step);
    }

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
    const test_step = b.step("test", "Run the std-only tests: the bridge's, and reading compiler diagnostics");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(diagnostics).step);
}

/// Copies `fizzy-mcp` into `<plugins>/agent/`, the directory `fizzy.plugin.install` puts the
/// library in: `$FIZZY_PROFILE/plugins` when that is set, else fizzy's own plugins directory.
/// Skipped, with a warning, where neither resolves (a bare CI runner).
const BesidePlugin = struct {
    step: std.Build.Step,
    exe: *std.Build.Step.Compile,

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
        const self: *BesidePlugin = @fieldParentPtr("step", step);
        const b = step.owner;
        const io = b.graph.io;
        const plugins = pluginsDir(b) orelse {
            std.log.warn("agent: no plugins directory here; fizzy-mcp stays in zig-out/bin", .{});
            return;
        };
        const dir = try std.fs.path.join(b.allocator, &.{ plugins, "agent" });
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        const name = if (b.graph.host.result.os.tag == .windows) "fizzy-mcp.exe" else "fizzy-mcp";
        const dest = try std.fs.path.join(b.allocator, &.{ dir, name });
        const src = self.exe.getEmittedBin().getPath2(b, step);
        const data = try std.Io.Dir.cwd().readFileAlloc(io, src, b.allocator, .limited(64 * 1024 * 1024));
        const tmp = try std.fmt.allocPrint(b.allocator, "{s}.part", .{dest});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = data, .flags = .{ .permissions = .fromMode(0o755) } });
        try std.Io.Dir.renameAbsolute(tmp, dest, io);
        std.log.info("agent: installed fizzy-mcp → {s}", .{dest});
    }

    /// As `fizzy.plugin.install` resolves it (`sdk/plugin_sdk.zig`'s `fizzyPluginsDir`).
    fn pluginsDir(b: *std.Build) ?[]const u8 {
        const env = &b.graph.environ_map;
        if (env.get("FIZZY_PROFILE")) |profile| if (profile.len > 0)
            return std.fs.path.resolve(b.allocator, &.{ b.build_root.path orelse ".", profile, "plugins" }) catch null;
        const join = std.fs.path.join;
        return switch (b.graph.host.result.os.tag) {
            .macos => join(b.allocator, &.{ env.get("HOME") orelse return null, "Library", "Application Support", "fizzy", "plugins" }) catch null,
            .windows => join(b.allocator, &.{ env.get("LOCALAPPDATA") orelse return null, "fizzy", "plugins" }) catch null,
            else => if (env.get("XDG_CONFIG_HOME")) |x|
                join(b.allocator, &.{ x, "fizzy", "plugins" }) catch null
            else
                join(b.allocator, &.{ env.get("HOME") orelse return null, ".config", "fizzy", "plugins" }) catch null,
        };
    }
};
