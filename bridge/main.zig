//! `fizzy-mcp`: fizzy, as an MCP server an agent starts (Claude Code, Codex, Grok's CLI, …).
//!
//! It speaks MCP on stdin/stdout — newline-delimited JSON-RPC — and passes each tool call to the
//! agent plugin in a running fizzy, over the socket `connection.zon` names: a ZON request a line,
//! a ZON answer a line (`src/Server.zig`). Standard library only, so it builds for every target
//! in a second and needs nothing beside it.
//!
//! ```sh
//! claude mcp add fizzy -- fizzy-mcp                      # the fizzy you use
//! claude mcp add fizzy-sandbox -- fizzy-mcp --profile ~/fizzy-sandbox
//! ```
//!
//! fizzy need not be running when the agent starts: the bridge connects on the first call, and
//! again whenever fizzy has restarted since (a new socket, a new token).
const std = @import("std");
const Io = std.Io;
const json = std.json;
const app_build = @import("app_build.zig");

/// No stack dump for an errno std did not expect. Its Unix-socket connect has no
/// `ConnectionRefused` (Zig 0.16), so a stale `agent.sock` with nothing listening (fizzy crashed)
/// reaches `posix.unexpectedErrno`, which in Debug printed a trace on every call. The error itself
/// still arrives, as `error.Unexpected`, and every caller here answers it.
pub const std_options: std.Options = .{ .unexpected_error_tracing = false };

const protocol_version = "2025-06-18";

const Tool = struct {
    /// The MCP tool's name.
    name: []const u8,
    /// The plugin's tool it calls (`src/tools.zig`).
    calls: []const u8,
    description: []const u8,
    /// JSON Schema of its arguments.
    schema: []const u8,
};

/// What an agent sees. Commands are not listed one tool each: there are a hundred or more, most
/// of which a task never needs, and every listed tool costs the agent context on every turn.
/// `fizzy_commands` finds them; `fizzy_call` runs one.
const tools = [_]Tool{
    .{
        .name = "fizzy_screen",
        .calls = "ui.snapshot",
        .description =
        \\What is on fizzy's screen now, as text: one line per widget worth naming — role, name,
        \\tag (stable, for ui steps), rect in physical pixels, focused, parent index. Read it
        \\before acting and after, as a person would look.
        ,
        .schema =
        \\{"type":"object","properties":{}}
        ,
    },
    .{
        .name = "fizzy_act",
        .calls = "ui.act",
        .description =
        \\Drive fizzy as a person does: the pointer moves, clicks and types on screen, through the
        \\same widgets, and a person's own input stops it. Steps run in order; each is an object
        \\with one key:
        \\  {"click": {"tag": "workbench.file:/p/a.zig"}}  or  {"click": {"x": 120, "y": 340}}
        \\  {"double_click": {...}}  {"move": {...}}       (points as in fizzy_screen's rects)
        \\  {"type": "text to type"}
        \\  {"key": "mod+s"}  (chords as the keymap spells them; "mod" is cmd on macOS, ctrl elsewhere)
        \\  {"wait_for": "tag"}  (until that widget is drawn)
        \\  {"command": "workbench.newFile"}  (as its menu row would; use fizzy_call for arguments)
        \\Answers how it ended and, unless "snapshot" is false, the screen after.
        ,
        .schema =
        \\{"type":"object","properties":{
        \\"steps":{"type":"array","items":{"type":"object"}},
        \\"snapshot":{"type":"boolean","default":true},
        \\"timeout_ms":{"type":"integer","default":10000}},"required":["steps"]}
        ,
    },
    .{
        .name = "fizzy_run",
        .calls = "ui.run",
        .description =
        \\Run a script in fizzy and get one report: do several things in one call instead of one
        \\call each. Steps run in order; each is an object with one key. Input and waits play as a
        \\person's would (a click of theirs stops the run):
        \\  {"click": {"tag": "..."}} or {"click": {"x": 120, "y": 340}}, {"double_click": ...},
        \\  {"move": ...}, {"type": "text"}, {"key": "mod+s"}, {"command": "id"},
        \\  {"wait_for": "tag"}, {"wait_gone": "tag"}
        \\The rest run between them:
        \\  {"call": {"id": "text.write", "args": {...}}}  a command with arguments; its result is reported
        \\  {"expect": {"tag": "...", "shown": true}}    fails the run if not so, now
        \\  {"settle": {}}                               wait until nothing is in flight
        \\  {"screen": {}}                               what is on screen, into the report
        \\  {"profile": {"ms": 500}}                     the profiler's report for that long
        \\The first step that fails ends the run; the report says which (failed_at) and why.
        \\Waits and settle give up after timeout_ms.
        ,
        .schema =
        \\{"type":"object","properties":{
        \\"steps":{"type":"array","items":{"type":"object"}},
        \\"timeout_ms":{"type":"integer","default":10000}},"required":["steps"]}
        ,
    },
    .{
        .name = "fizzy_build",
        .calls = "plugin.build",
        .description =
        \\Build a plugin and see it running, in one call: zig build in its directory (installing
        \\into this fizzy), the compiler's errors as file, line, column and message, then fizzy's
        \\reload of the rebuilt binary (its timing, or why it failed), then an optional check:
        \\steps as fizzy_run takes them, run on what came back. The person's open documents stay
        \\open across the reload. Not for the agent plugin itself.
        \\Given fizzy's own repo (or an app built on fizzy) instead: zig build there, then fizzy
        \\restarting into the new executable (Settings > Restart when rebuilt), every document
        \\kept; the report says how long it was gone, or that it did not come back.
        ,
        .schema =
        \\{"type":"object","properties":{
        \\"path":{"type":"string","description":"the plugin's directory, or the app's repo, absolute"},
        \\"optimize":{"type":"string","enum":["Debug","ReleaseSafe","ReleaseFast","ReleaseSmall"]},
        \\"check":{"type":"array","items":{"type":"object"}},
        \\"timeout_ms":{"type":"integer","default":120000}},"required":["path"]}
        ,
    },
    .{
        .name = "fizzy_commands",
        .calls = "commands.list",
        .description =
        \\Every command fizzy's plugins offer — the agent's API to each plugin: id, title, whether
        \\it can run now, and its parameters (kind, description, default, choices, range).
        ,
        .schema =
        \\{"type":"object","properties":{}}
        ,
    },
    .{
        .name = "fizzy_call",
        .calls = "commands.call",
        .description =
        \\Run a command (fizzy_commands lists them) with its arguments as a JSON object, keyed by
        \\parameter. Answers its result, or why it did not run.
        ,
        .schema =
        \\{"type":"object","properties":{
        \\"id":{"type":"string"},
        \\"args":{"type":"object"}},"required":["id"]}
        ,
    },
    .{
        .name = "fizzy_settled",
        .calls = "ui.settled",
        .description =
        \\Wait until fizzy has nothing in flight — no animation, load or tape — or the time is up.
        \\Answers true when settled.
        ,
        .schema =
        \\{"type":"object","properties":{"timeout_ms":{"type":"integer","default":5000}}}
        ,
    },
    .{
        .name = "fizzy_profile",
        .calls = "profile.report",
        .description =
        \\Measure fizzy for a while and answer the profiler's report: fps, frame work and its
        \\worst, then time per plugin and per scope. Use it instead of adding logging.
        ,
        .schema =
        \\{"type":"object","properties":{"ms":{"type":"integer","default":1000}}}
        ,
    },
    .{
        .name = "fizzy_tape",
        .calls = "tape.play",
        .description =
        \\Play a live tape (ZON, as fizzy's demos are written) and answer its ticket; for timed or
        \\long input fizzy_act cannot say. fizzy_tape_outcome tells how it went.
        ,
        .schema =
        \\{"type":"object","properties":{"tape":{"type":"string"}},"required":["tape"]}
        ,
    },
    .{
        .name = "fizzy_tape_outcome",
        .calls = "tape.outcome",
        .description = "How a tape fizzy_tape started is going, or ended.",
        .schema =
        \\{"type":"object","properties":{"ticket":{"type":"integer"}},"required":["ticket"]}
        ,
    },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var profile: ?[]const u8 = init.environ_map.get("FIZZY_PROFILE");
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--profile") and i + 1 < args.len) {
            i += 1;
            profile = args[i];
        } else if (std.mem.startsWith(u8, a, "--profile=")) {
            profile = a["--profile=".len..];
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            var buf: [256]u8 = undefined;
            var w = Io.File.stdout().writer(io, &buf);
            try w.interface.writeAll("usage: fizzy-mcp [--profile DIR]\nfizzy as an MCP server on stdin/stdout; see the agent plugin's README.\n");
            try w.interface.flush();
            return;
        }
    }

    var bridge: Bridge = .{
        .gpa = gpa,
        .io = io,
        .connection_path = try connectionPath(init.arena.allocator(), init.environ_map, profile),
    };
    defer bridge.disconnect();
    defer if (bridge.hello) |h| gpa.free(h);

    var in_buf: [1 << 16]u8 = undefined;
    var out_buf: [1 << 16]u8 = undefined;
    var stdin = Io.File.stdin().readerStreaming(io, &in_buf);
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    while (true) {
        const line = stdin.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return,
            error.StreamTooLong => {
                _ = stdin.interface.discardDelimiterInclusive('\n') catch return;
                continue;
            },
            else => return err,
        };
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        bridge.message(arena.allocator(), std.mem.trim(u8, line, " \t\r\n"), &stdout.interface) catch |err| {
            std.log.err("fizzy-mcp: {t}", .{err});
        };
        try stdout.interface.flush();
    }
}

/// `connection.zon`, which the agent plugin writes into its own directory under the plugins
/// directory: the profile's, or the platform's (as `sdk/plugin_sdk.zig` installs to).
fn connectionPath(arena: std.mem.Allocator, env: *const std.process.Environ.Map, profile: ?[]const u8) ![]const u8 {
    const tail = [_][]const u8{ "plugins", "agent", "connection.zon" };
    if (profile) |p| return std.fs.path.join(arena, &.{ p, tail[0], tail[1], tail[2] });
    const os = @import("builtin").os.tag;
    const base: []const u8 = switch (os) {
        .macos => try std.fs.path.join(arena, &.{ env.get("HOME") orelse return error.NoHome, "Library", "Application Support" }),
        .windows => env.get("LOCALAPPDATA") orelse return error.NoLocalAppData,
        else => env.get("XDG_CONFIG_HOME") orelse try std.fs.path.join(arena, &.{ env.get("HOME") orelse return error.NoHome, ".config" }),
    };
    return std.fs.path.join(arena, &.{ base, "fizzy", tail[0], tail[1], tail[2] });
}

pub const Bridge = struct {
    gpa: std.mem.Allocator,
    io: Io,
    connection_path: []const u8,
    link: ?*Link = null,
    next_id: u64 = 1,
    /// What fizzy said to the last `hello`: its tools and the executable it runs from. Owned.
    hello: ?[]u8 = null,

    /// A connection to the plugin, said hello on.
    const Link = struct {
        stream: Io.net.Stream,
        read_buf: [1 << 16]u8,
        write_buf: [1 << 14]u8,
        reader: Io.net.Stream.Reader,
        writer: Io.net.Stream.Writer,
    };

    const Wire = struct {
        const Request = struct { id: u64, tool: []const u8, args: []const u8 = "" };
        const Response = struct { id: u64, ok: ?[]const u8 = null, err: ?[]const u8 = null };
    };

    pub const Answer = union(enum) { ok: []const u8, err: []const u8 };

    fn disconnect(self: *Bridge) void {
        const link = self.link orelse return;
        link.stream.close(self.io);
        self.gpa.destroy(link);
        self.link = null;
    }

    fn connect(self: *Bridge, arena: std.mem.Allocator) ![]const u8 {
        const Connection = struct { socket: []const u8, token: []const u8 };
        const source = Io.Dir.cwd().readFileAllocOptions(self.io, self.connection_path, arena, .limited(64 * 1024), .of(u8), 0) catch
            return error.FizzyNotRunning;
        const c = std.zon.parse.fromSliceAlloc(Connection, arena, source, null, .{ .ignore_unknown_fields = true }) catch
            return error.BadConnectionFile;
        const addr = try Io.net.UnixAddress.init(c.socket);
        const stream = addr.connect(self.io) catch return error.FizzyNotRunning;
        const link = try self.gpa.create(Link);
        link.stream = stream;
        link.reader = stream.reader(self.io, &link.read_buf);
        link.writer = stream.writer(self.io, &link.write_buf);
        self.link = link;
        var hello: std.Io.Writer.Allocating = .init(arena);
        try std.zon.stringify.serialize(.{ .token = c.token }, .{ .whitespace = false }, &hello.writer);
        return switch (try self.exchange(arena, "hello", hello.written())) {
            .ok => |s| {
                self.keepHello(s);
                return s;
            },
            .err => |e| {
                self.disconnect();
                std.log.err("fizzy-mcp: fizzy refused the connection: {s}", .{e});
                return error.Refused;
            },
        };
    }

    fn keepHello(self: *Bridge, answer: []const u8) void {
        if (self.hello) |h| self.gpa.free(h);
        self.hello = self.gpa.dupe(u8, answer) catch null;
    }

    /// Whether the fizzy this bridge is connected to still answers. A fizzy quitting closes the
    /// connection, so this is false once it has gone (and the link is dropped).
    pub fn probe(self: *Bridge, arena: std.mem.Allocator) bool {
        if (self.link == null) return false;
        const answer = self.exchange(arena, "hello", "") catch {
            self.disconnect();
            return false;
        };
        switch (answer) {
            .ok => |s| self.keepHello(s),
            .err => {},
        }
        return true;
    }

    /// Connect afresh: to the fizzy `connection.zon` names now.
    pub fn reconnect(self: *Bridge, arena: std.mem.Allocator) bool {
        self.disconnect();
        _ = self.connect(arena) catch return false;
        return true;
    }

    /// The executable the fizzy answering now runs from, or null when none is running.
    pub fn executable(self: *Bridge, arena: std.mem.Allocator) ?[]const u8 {
        if (!self.probe(arena)) {
            if (!self.reconnect(arena)) return null;
        }
        const source = arena.dupeZ(u8, self.hello orelse return null) catch return null;
        const Hello = struct { executable: []const u8 = "" };
        const h = std.zon.parse.fromSliceAlloc(Hello, arena, source, null, .{ .ignore_unknown_fields = true }) catch return null;
        return if (h.executable.len > 0) h.executable else null;
    }

    /// The token `connection.zon` holds now: a new one is a new fizzy.
    pub fn connectionToken(self: *Bridge, arena: std.mem.Allocator) ?[]const u8 {
        const source = Io.Dir.cwd().readFileAllocOptions(self.io, self.connection_path, arena, .limited(64 * 1024), .of(u8), 0) catch return null;
        const c = std.zon.parse.fromSliceAlloc(struct { token: []const u8 }, arena, source, null, .{ .ignore_unknown_fields = true }) catch return null;
        return c.token;
    }

    pub fn runTool() Tool {
        for (tools) |t| if (eql(t.calls, "ui.run")) return t;
        unreachable;
    }

    /// One request and its answer, on the open link.
    fn exchange(self: *Bridge, arena: std.mem.Allocator, tool: []const u8, args: []const u8) !Answer {
        const link = self.link.?;
        const id = self.next_id;
        self.next_id += 1;
        const w = &link.writer.interface;
        try std.zon.stringify.serialize(Wire.Request{ .id = id, .tool = tool, .args = args }, .{ .whitespace = false }, w);
        try w.writeByte('\n');
        try w.flush();
        const line = try link.reader.interface.takeDelimiterInclusive('\n');
        const source = try arena.dupeZ(u8, std.mem.trimEnd(u8, line, "\r\n"));
        const r = try std.zon.parse.fromSliceAlloc(Wire.Response, arena, source, null, .{ .ignore_unknown_fields = true });
        if (r.err) |e| return .{ .err = e };
        return .{ .ok = r.ok orelse "" };
    }

    /// A tool call to fizzy, connecting first if need be, and once more if fizzy went away since.
    pub fn call(self: *Bridge, arena: std.mem.Allocator, tool: []const u8, args: []const u8) Answer {
        for (0..2) |_| {
            if (self.link == null) _ = self.connect(arena) catch |err| return .{ .err = switch (err) {
                error.FizzyNotRunning => "fizzy is not running, or its agent plugin is not loaded (no connection.zon, or nothing listening on its socket)",
                error.BadConnectionFile => "the agent plugin's connection.zon could not be read",
                error.Refused => "fizzy refused the connection: the token in connection.zon is stale",
                else => @errorName(err),
            } };
            return self.exchange(arena, tool, args) catch {
                self.disconnect();
                continue;
            };
        }
        return .{ .err = "lost the connection to fizzy" };
    }

    fn message(self: *Bridge, arena: std.mem.Allocator, line: []const u8, out: *Io.Writer) !void {
        if (line.len == 0) return;
        const parsed = json.parseFromSliceLeaky(json.Value, arena, line, .{}) catch {
            return reply(out, .null, .{ .@"error" = .{ .code = -32700, .message = "parse error" } });
        };
        const msg = switch (parsed) {
            .object => |o| o,
            else => return reply(out, .null, .{ .@"error" = .{ .code = -32600, .message = "invalid request" } }),
        };
        const method = switch (msg.get("method") orelse return) {
            .string => |s| s,
            else => return,
        };
        // A notification has no id and gets no answer.
        const id = msg.get("id") orelse return;
        const params: ?json.ObjectMap = if (msg.get("params")) |p| switch (p) {
            .object => |o| o,
            else => null,
        } else null;

        if (eql(method, "initialize")) {
            const version = if (params) |p| if (p.get("protocolVersion")) |v| switch (v) {
                .string => |s| s,
                else => protocol_version,
            } else protocol_version else protocol_version;
            return reply(out, id, .{ .result = .{
                .protocolVersion = version,
                .capabilities = .{ .tools = .{ .listChanged = false } },
                .serverInfo = .{ .name = "fizzy", .version = "0.1.0" },
                .instructions = instructions,
            } });
        }
        if (eql(method, "ping")) return reply(out, id, .{ .result = .{} });
        if (eql(method, "tools/list")) return listTools(out, id);
        if (eql(method, "tools/call")) {
            const p = params orelse return reply(out, id, .{ .@"error" = .{ .code = -32602, .message = "tools/call needs params" } });
            const name = switch (p.get("name") orelse .null) {
                .string => |s| s,
                else => return reply(out, id, .{ .@"error" = .{ .code = -32602, .message = "tools/call needs a name" } }),
            };
            const tool = for (tools) |t| {
                if (eql(t.name, name)) break t;
            } else return reply(out, id, .{ .@"error" = .{ .code = -32602, .message = "no such tool" } });
            const arguments: json.Value = p.get("arguments") orelse .{ .object = .{} };
            const answer = if (appBuildArgs(self.io, tool, arguments)) |a|
                app_build.run(self, arena, a)
            else switch (self.toolArgs(arena, tool, arguments)) {
                .ok => |zon_args| self.call(arena, tool.calls, zon_args),
                .err => |e| Answer{ .err = e },
            };
            const text, const failed = switch (answer) {
                .ok => |s| .{ s, false },
                .err => |s| .{ s, true },
            };
            return reply(out, id, .{ .result = .{
                .content = &[_]struct { type: []const u8, text: []const u8 }{.{ .type = "text", .text = text }},
                .isError = failed,
            } });
        }
        return reply(out, id, .{ .@"error" = .{ .code = -32601, .message = "method not found" } });
    }

    /// The plugin's arguments, as ZON, from the MCP call's JSON.
    pub fn toolArgs(self: *Bridge, arena: std.mem.Allocator, tool: Tool, arguments: json.Value) Answer {
        var w: Io.Writer.Allocating = .init(arena);
        if (eql(tool.calls, "commands.call")) {
            const o = switch (arguments) {
                .object => |o| o,
                else => return .{ .err = "fizzy_call takes {\"id\", \"args\"}" },
            };
            const id = switch (o.get("id") orelse .null) {
                .string => |s| s,
                else => return .{ .err = "fizzy_call needs the command's id" },
            };
            // An enumeration's value is a string in JSON and an enum literal in ZON: which
            // parameters are enumerations, the command list says.
            const enums = self.enumParams(arena, id);
            var inner: Io.Writer.Allocating = .init(arena);
            toZon(&inner.writer, o.get("args") orelse .{ .object = .{} }, enums) catch return .{ .err = "out of memory" };
            std.zon.stringify.serialize(.{ .id = id, .args = inner.written() }, .{ .whitespace = false }, &w.writer) catch return .{ .err = "out of memory" };
            return .{ .ok = w.written() };
        }
        if (eql(tool.calls, "ui.run") or eql(tool.calls, "plugin.build")) {
            // A `call` step's args are a JSON object here and ZON text for the plugin, its enum
            // parameters as literals (as for fizzy_call).
            const o = switch (arguments) {
                .object => |o| o,
                else => return .{ .err = "fizzy_run takes {\"steps\": [...]}" },
            };
            const list = o.get("steps") orelse o.get("check");
            if (list) |steps| if (steps == .array) for (steps.array.items) |*step| {
                if (step.* != .object) continue;
                const call_step = step.object.getPtr("call") orelse continue;
                if (call_step.* != .object) continue;
                const id = switch (call_step.object.get("id") orelse .null) {
                    .string => |str| str,
                    else => continue,
                };
                const args = call_step.object.get("args") orelse continue;
                var inner: Io.Writer.Allocating = .init(arena);
                toZon(&inner.writer, args, self.enumParams(arena, id)) catch return .{ .err = "out of memory" };
                call_step.object.put(arena, "args", .{ .string = inner.written() }) catch return .{ .err = "out of memory" };
            };
            toZon(&w.writer, arguments, &.{}) catch return .{ .err = "out of memory" };
            return .{ .ok = w.written() };
        }
        if (eql(tool.calls, "tape.play")) {
            const o = switch (arguments) {
                .object => |o| o,
                else => return .{ .err = "fizzy_tape takes {\"tape\"}" },
            };
            return switch (o.get("tape") orelse .null) {
                .string => |s| .{ .ok = s },
                else => .{ .err = "fizzy_tape needs the tape, as ZON text" },
            };
        }
        toZon(&w.writer, arguments, &.{}) catch return .{ .err = "out of memory" };
        return .{ .ok = w.written() };
    }

    /// The keys of `id`'s enumeration parameters, from the command list. Empty when unknown.
    fn enumParams(self: *Bridge, arena: std.mem.Allocator, id: []const u8) []const []const u8 {
        const Listed = struct {
            id: []const u8,
            params: []const struct { key: []const u8, kind: []const u8 } = &.{},
        };
        const list = switch (self.call(arena, "commands.list", "")) {
            .ok => |s| s,
            .err => return &.{},
        };
        const source = arena.dupeZ(u8, list) catch return &.{};
        const commands = std.zon.parse.fromSliceAlloc([]const Listed, arena, source, null, .{ .ignore_unknown_fields = true }) catch return &.{};
        for (commands) |c| {
            if (!eql(c.id, id)) continue;
            var keys: std.ArrayListUnmanaged([]const u8) = .empty;
            for (c.params) |p| if (eql(p.kind, "enumeration")) keys.append(arena, p.key) catch {};
            return keys.items;
        }
        return &.{};
    }
};

/// `fizzy_build`'s arguments when its path is an app's repo (fizzy's own, or an app on fizzy)
/// rather than a plugin's: built and restarted into here, since the plugin goes with the old
/// fizzy (`app_build.zig`). Null for every other call.
fn appBuildArgs(io: Io, tool: Tool, arguments: json.Value) ?app_build.Args {
    if (!eql(tool.calls, "plugin.build") or arguments != .object) return null;
    const o = arguments.object;
    const path = switch (o.get("path") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    if (!app_build.isApp(io, path)) return null;
    return .{
        .path = path,
        .optimize = if (o.get("optimize")) |v| switch (v) {
            .string => |s| s,
            else => "",
        } else "",
        .check = o.get("check"),
        .timeout_ms = if (o.get("timeout_ms")) |v| switch (v) {
            .integer => |n| @intCast(@max(n, 1000)),
            else => 120_000,
        } else 120_000,
    };
}

const instructions =
    \\fizzy is a native editor whose every feature is a plugin. These tools drive a running fizzy
    \\the way a person does, so the person watching sees each step. Look with fizzy_screen, act
    \\with fizzy_act (pointer, keys, typing) or fizzy_call (a plugin's command, with arguments —
    \\fizzy_commands lists them), and measure with fizzy_profile rather than adding logging.
;

fn listTools(out: *Io.Writer, id: json.Value) !void {
    try out.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try json.Stringify.value(id, .{}, out);
    try out.writeAll(",\"result\":{\"tools\":[");
    for (tools, 0..) |t, n| {
        if (n > 0) try out.writeByte(',');
        try out.writeAll("{\"name\":");
        try json.Stringify.value(t.name, .{}, out);
        try out.writeAll(",\"description\":");
        try json.Stringify.value(t.description, .{}, out);
        try out.writeAll(",\"inputSchema\":");
        // The schemas are written across lines for reading; JSON-RPC here is one line a message.
        for (t.schema) |c| if (c != '\n') try out.writeByte(c);
        try out.writeByte('}');
    }
    try out.writeAll("]}}\n");
}

fn reply(out: *Io.Writer, id: json.Value, body: anytype) !void {
    const B = @TypeOf(body);
    try out.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try json.Stringify.value(id, .{}, out);
    inline for (@typeInfo(B).@"struct".fields) |f| {
        try out.writeAll(",\"" ++ f.name ++ "\":");
        try json.Stringify.value(@field(body, f.name), .{}, out);
    }
    try out.writeAll("}\n");
}

/// JSON as ZON: objects as structs, arrays as tuples, and the strings under `enum_keys` (at the
/// top level) as enum literals.
fn toZon(w: *Io.Writer, v: json.Value, enum_keys: []const []const u8) !void {
    switch (v) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |n| try w.print("{d}", .{n}),
        .float => |f| try w.print("{d}", .{f}),
        .number_string => |s| try w.writeAll(s),
        .string => |s| try std.zon.stringify.serialize(s, .{}, w),
        .array => |a| {
            try w.writeAll(".{");
            for (a.items, 0..) |item, n| {
                if (n > 0) try w.writeAll(", ");
                try toZon(w, item, &.{});
            }
            try w.writeAll("}");
        },
        .object => |o| {
            try w.writeAll(".{");
            var it = o.iterator();
            var n: usize = 0;
            while (it.next()) |e| : (n += 1) {
                if (n > 0) try w.writeAll(", ");
                try w.print(".{f} = ", .{std.zig.fmtId(e.key_ptr.*)});
                const is_enum = for (enum_keys) |k| {
                    if (eql(k, e.key_ptr.*)) break true;
                } else false;
                if (is_enum and e.value_ptr.* == .string) {
                    try w.print(".{f}", .{std.zig.fmtId(e.value_ptr.string)});
                } else try toZon(w, e.value_ptr.*, &.{});
            }
            try w.writeAll("}");
        },
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "JSON arguments read as ZON" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try json.parseFromSliceLeaky(json.Value, a,
        \\{"steps":[{"click":{"tag":"a.b"}},{"type":"hi \"there\"\n"},{"key":"mod+s"}],"snapshot":false}
    , .{});
    var w: Io.Writer.Allocating = .init(a);
    try toZon(&w.writer, v, &.{});
    try std.testing.expectEqualStrings(
        \\.{.steps = .{.{.click = .{.tag = "a.b"}}, .{.@"type" = "hi \"there\"\n"}, .{.key = "mod+s"}}, .snapshot = false}
    , w.written());

    // And parse back as the plugin's types would.
    const Step = union(enum) { click: struct { tag: []const u8 }, type: []const u8, key: []const u8 };
    const Args = struct { steps: []const Step, snapshot: bool = true };
    const parsed = try std.zon.parse.fromSliceAlloc(Args, a, try a.dupeZ(u8, w.written()), null, .{});
    try std.testing.expectEqualStrings("hi \"there\"\n", parsed.steps[1].type);
    try std.testing.expect(!parsed.snapshot);
}

test "an enumeration's string becomes an enum literal" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try json.parseFromSliceLeaky(json.Value, a,
        \\{"mode":"split right","line":12}
    , .{});
    var w: Io.Writer.Allocating = .init(a);
    try toZon(&w.writer, v, &.{"mode"});
    try std.testing.expectEqualStrings(
        \\.{.mode = .@"split right", .line = 12}
    , w.written());
}
