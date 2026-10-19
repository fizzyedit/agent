//! What each tool does, on the UI thread. A tool either answers in the frame it is taken, or
//! waits — for a snapshot to be taken, a tape to play out, fizzy to settle, a measurement to run —
//! and is answered from a later frame (`frame` checks what waits).
//!
//! The tools are the `agent.*` commands (`commands.zig`), so anything that calls a command reaches
//! them: fizzy's control server (`/mcp`, `POST /commands/agent.run`), another plugin, and the
//! socket `fizzy-mcp` speaks, whose requests are routed to the same commands (`handle`). Who is
//! calling is the host's acting author (`Host.author`), not a connection: a call through the
//! control server is its client's, one through the socket is that connection's (`connAuthor`).
//! What an author works on is kept by the author's index into the host's authors (`who`), which
//! the host keeps for its life.
//!
//! Every tool's arguments and result are ZON.
//!
//! | socket tool | command | arguments | result |
//! |---|---|---|---|
//! | `hello` | — | `.{ .token, .client }` | the tools, what fizzy offers, and the executable it runs from |
//! | `commands.list` | — | `.{ .prefix }` | no prefix: a line per command, its id and title (and "(not now)" when it cannot run); with one (`"pixi."`, or a whole id): those commands in full, parameters too (kind, description, default) |
//! | `ui.snapshot` | (`fizzy.screen`) | — | what is on screen (`automation` service): fizzy's windows, then each widget's role, name, tag, rect, parent and window |
//! | `ui.settled` | (`fizzy.settled`) | `.{ .timeout_ms }` | once nothing is in flight, or the time is up |
//! | `commands.call` | `agent.call` | `.{ .id, .args = "<ZON>" }` | its result, or why not |
//! | `ui.capture` | `agent.capture` | `.{ .path, .window }` | a picture of a window (the main one, one by its tag, or `"*"` for all), as fizzy drew it, written raw to `path` (`"FZPX"`, width and height as little-endian `u32`, then premultiplied RGBA rows: the bridge scales and encodes it); on screen or not |
//! | `ui.act` | `agent.act` | `.{ .steps, .snapshot, .timeout_ms }` | input played as a person's, then (by default) the screen |
//! | `ui.run` | `agent.run` | `.{ .steps, .timeout_ms }` | a script across frames, one report |
//! | `plugin.build` | `agent.build` | `.{ .path, .optimize, .check, .timeout_ms }` | build, reload, check |
//! | `tape.play` / `tape.outcome` | `agent.tape` / `agent.tapeOutcome` | a live tape (the command: `.{ .tape }`) / `.{ .ticket }` | a ticket / how it ended |
//! | `profile.report` | `agent.profile` | `.{ .ms, .drive, .startup }` | the profiler's report after `ms` of frames: per plugin, per scope |
//! | `doc.claim` | `agent.claim` | `.{ .path, .label }` | a claim on an open document (`sdk.Claim`): the person's input to it waits until `agent.release`, the connection closes, or they press Stop. For work that cannot share the document; an agent's commands do not need one |
//! | `doc.release` | `agent.release` | `.{ .claim }`, `.{ .path }`, or neither for every session the caller has | `.{ .tapes }`: the sessions it recorded (`Recording`) |
const std = @import("std");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const core = @import("core");
const Server = @import("Server.zig");
const Run = @import("Run.zig");
const measure = @import("measure.zig");
const Build = @import("Build.zig");
const Recording = @import("Recording.zig");

const Automation = sdk.services.automation.Api;

/// Calls waiting on something, answered from a later frame. UI thread only.
var waiting: std.ArrayListUnmanaged(Waiting) = .empty;

const Waiting = struct {
    to: Reply,
    until: union(enum) {
        snapshot: Automation.SnapshotTicket,
        /// A picture, written to `path` (the host's allocation) once taken.
        capture: struct { ticket: Automation.CaptureTicket, path: []u8 },
        settled: i96,
        run: *Run,
        build: *Build,
        profile: struct { until: i96, drive: bool, startup: bool = false },
    },
};

/// Where a tool's answer goes, and whose call it was (`who`).
pub const Reply = struct {
    /// The caller, as an index into the host's authors.
    who: u32,
    to: union(enum) {
        /// A socket request (`fizzy-mcp`'s), answered through the server.
        req: *Server.Request,
        /// An `agent.*` command's call, answered through `Host.finishCall`, before its `runWith`
        /// returns or in a later frame.
        ticket: u32,
    },

    /// Answer, with whatever the caller should hear besides (a claim the person stopped) after it
    /// as a ZON comment, which leaves a ZON result readable.
    pub fn send(self: Reply, host: *sdk.Host, ok: bool, text: []const u8) void {
        const notice = takeNotice(self.who);
        defer if (notice) |n| host.allocator.free(n);
        switch (self.to) {
            .req => |r| {
                if (notice) |n| r.notice = host.allocator.dupe(u8, n) catch null;
                r.answer(the_server.?, ok, text);
            },
            .ticket => |t| {
                const with = if (notice) |n| std.fmt.allocPrint(host.allocator, "{s}\n// {s}", .{ text, n }) catch null else null;
                defer if (with) |w| host.allocator.free(w);
                const out = with orelse text;
                host.finishCall(t, if (ok) .{ .ok = out } else .{ .failed = out });
            },
        }
    }
};

fn now() i96 {
    return std.Io.Clock.boot.now(dvui.io).nanoseconds;
}

fn ms(n: u32) i96 {
    return @as(i96, n) * std.time.ns_per_ms;
}

/// The agent plugin itself, which claims documents (`agent.claim`) and owns its commands. Set by
/// `plugin.zig`.
pub var owner: ?*sdk.Plugin = null;
/// The host, set by `plugin.zig`: authors are read through it (`authorOf`).
pub var the_host: ?*sdk.Host = null;
/// The socket's server while it serves (desktop): where a socket request's answer goes.
pub var the_server: ?*Server = null;

/// An author's work on a document, from their first command on it: recorded as it goes, and
/// written as a tape when it ends (`agent.release`, the connection closing, the document closing).
/// It takes nothing from the person: they keep working in the document, and the plugins that own
/// it keep the two from colliding (pixi waits out a stroke of theirs). A `claim` only when the
/// agent asked to hold the document (`agent.claim`). UI thread only.
var held: std.ArrayListUnmanaged(Held) = .empty;
const Held = struct {
    /// Whose: an index into the host's authors.
    who: u32,
    path: []u8,
    claim: ?u32 = null,
    /// The session on it so far, written as a tape when it ends.
    rec: ?Recording = null,
};

/// What each socket connection is called, from its client's name in `hello` ("Claude"): what the
/// person reads beside its steps (`sdk.Author.label`). A connection with no name is "An agent".
var labels: std.AutoHashMapUnmanaged(u32, []u8) = .empty;

/// The author `who` names (an index into the host's authors, as `who` always is here).
pub fn authorOf(who: u32) sdk.Author {
    return the_host.?.authors.items[who];
}

/// `author`'s index into the host's authors, which the host makes when it is new.
fn indexOf(host: *sdk.Host, a: sdk.Author) u32 {
    const outer = host.act(a);
    defer host.endAct(outer);
    return host.acted().author.?;
}

/// Socket connection `conn`, as an author.
fn connAuthor(host: *sdk.Host, conn: u32) u32 {
    return indexOf(host, .{ .kind = .agent, .plugin = "agent", .session = conn, .label = labels.get(conn) orelse "An agent" });
}

/// Who is calling a command now: the acting author when it is an agent (the control server's
/// client, the socket's connection), else one agent standing for every caller that does not say
/// (a `curl` call, a plugin's), so its steps still read as an agent's and not the person's.
pub fn caller(host: *sdk.Host) u32 {
    if (host.author().kind == .agent) return host.acted().author.?;
    // Session 0: no socket connection is numbered 0 (`Server.next_conn` starts at 1).
    return indexOf(host, .{ .kind = .agent, .plugin = "agent", .session = 0, .label = "An agent" });
}

/// What an author should hear with their next answer: a claim the person stopped. Texts in the
/// host's allocator.
var notices: std.ArrayListUnmanaged(struct { who: u32, text: []u8 }) = .empty;

fn takeNotice(who: u32) ?[]u8 {
    for (notices.items, 0..) |n, i| if (n.who == who) {
        _ = notices.swapRemove(i);
        return n.text;
    };
    return null;
}

/// Take what arrived on the socket and answer what can be, then what waits. Once a frame, from
/// `beginFrame`.
pub fn frame(host: *sdk.Host) void {
    if (the_server) |server| {
        var batch: std.ArrayListUnmanaged(*Server.Request) = .empty;
        defer batch.deinit(host.allocator);
        var closed: std.ArrayListUnmanaged(u32) = .empty;
        defer closed.deinit(host.allocator);
        server.take(&batch, &closed);
        var closed_authors: std.ArrayListUnmanaged(u32) = .empty;
        defer closed_authors.deinit(host.allocator);
        for (closed.items) |c| closed_authors.append(host.allocator, connAuthor(host, c)) catch {};
        tendClaims(host, closed_authors.items);
        for (closed.items) |c| if (labels.fetchRemove(c)) |kv| host.allocator.free(kv.value);
        for (batch.items) |req| handle(host, req);
    } else tendClaims(host, &.{});

    var i: usize = 0;
    while (i < waiting.items.len) {
        if (check(host, &waiting.items[i])) {
            _ = waiting.swapRemove(i);
        } else i += 1;
    }
}

/// Answer whatever still waits: fizzy is going, or the plugin is.
pub fn deinit(host: *sdk.Host) void {
    for (waiting.items) |w| {
        switch (w.until) {
            .run => |r| r.deinit(host.allocator),
            .build => |b| b.deinit(),
            .capture => |c| host.allocator.free(c.path),
            else => {},
        }
        w.to.send(host, false, "fizzy is closing");
    }
    waiting.deinit(host.allocator);
    for (held.items) |*h| {
        if (h.claim) |c| host.releaseClaim(c);
        if (finish(host, h)) |tape| host.allocator.free(tape);
        host.allocator.free(h.path);
    }
    held.deinit(host.allocator);
    for (notices.items) |n| host.allocator.free(n.text);
    notices.deinit(host.allocator);
    var it = labels.valueIterator();
    while (it.next()) |l| host.allocator.free(l.*);
    labels.deinit(host.allocator);
}

/// End the sessions of authors gone (`closed`: socket connections that closed) and on closed
/// documents, and turn claims the person stopped into a notice for the author that made them.
/// Nothing here waits on a clock: a session ends when something happens. A caller through the
/// control server ends its sessions with `agent.release`, or they end with the document; the
/// seam for ending them with its MCP session is an event the control server would emit then.
fn tendClaims(host: *sdk.Host, closed: []const u32) void {
    var i: usize = 0;
    while (i < held.items.len) {
        const h = &held.items[i];
        const gone = std.mem.indexOfScalar(u32, closed, h.who) != null or host.docFromPath(h.path) == null;
        if (gone) {
            if (h.claim) |c| host.releaseClaim(c);
            if (finish(host, h)) |tape| {
                std.log.info("agent: the session on {s} is a tape: {s}", .{ h.path, tape });
                host.allocator.free(tape);
            }
        } else if (h.claim != null and !host.claimHolds(h.claim.?)) {
            const tape = finish(host, h);
            defer if (tape) |t| host.allocator.free(t);
            const text = std.fmt.allocPrint(host.allocator, "the person pressed Stop on {s}: leave it be, and ask before claiming it again.{s}{s}", .{ h.path, if (tape != null) " The session so far is a tape: " else "", tape orelse "" }) catch null;
            if (text) |t| notices.append(host.allocator, .{ .who = h.who, .text = t }) catch host.allocator.free(t);
        } else {
            i += 1;
            continue;
        }
        host.allocator.free(h.path);
        _ = held.swapRemove(i);
    }
}

/// `agent.claim`: hold the open document `path`, the person reading `label` meanwhile.
pub fn claim(host: *sdk.Host, to: Reply, path: []const u8, label: []const u8) void {
    var buf: [32]u8 = undefined;
    const doc = host.docFromPath(path) orelse return to.send(host, false, "that document is not open: open it first (fizzy.openFiles)");
    const me = owner orelse return to.send(host, false, "the agent plugin is not registered");
    const h = session(host, to.who, doc, label) catch return to.send(host, false, "out of memory");
    const id = h.claim orelse host.claimDocument(me, doc.id, label) catch |err| return to.send(host, false, switch (err) {
        error.DocumentClaimed => "someone else is holding that document",
        else => "out of memory",
    });
    h.claim = id;
    to.send(host, true, std.fmt.bufPrint(&buf, ".{{ .claim = {d} }}", .{id}) catch "?");
}

/// Run command `id` as `who`'s step, as `agent.call` and a run's `call` steps both do: the session
/// on the document it works on begins before it runs (shown beside the person, its tape starting
/// from the document as it was), and the step goes into that session's tape, not into every one
/// the author has.
pub fn agentCall(host: *sdk.Host, who: u32, id: []const u8, args: []const u8, arena: std.mem.Allocator) sdk.Host.CommandOutcome {
    return switch (agentCallAwaiting(host, who, id, args, arena, null)) {
        .now => |o| o,
        // Nobody waits for it here (a script's step): started, as a menu would start it.
        .later => .{ .ok = null },
    };
}

/// `agentCall`, and `sink` hears a command that answers in a later frame (`agent.call` waiting on
/// `fizzy.settled`, say). A step answered later is noted in its session's tape when it is answered.
fn agentCallAwaiting(host: *sdk.Host, who: u32, id: []const u8, args: []const u8, arena: std.mem.Allocator, sink: ?sdk.Host.CallSink) sdk.Host.AwaitedOutcome {
    if (undoesAnother(host, who, id)) |active| return .{ .now = .{ .failed = std.fmt.allocPrint(
        arena,
        "{s} acts on the active document, {s}, which is not one you are working on: it would take back the person's steps. Take back your own by clearing what you drew and drawing it again.",
        .{ id, active },
    ) catch "undo acts on the active document, which is not yours" } };
    const doc_path: ?[]const u8 = if (target(host, id, arena.dupeSentinel(u8, args, 0) catch "", arena)) |doc| blk: {
        const h = session(host, who, doc, authorOf(who).label) catch break :blk null;
        break :blk arena.dupe(u8, h.path) catch null;
    } else null;
    // What the command opens or creates lands beside the person, not over their document, and
    // the steps it records are this author's.
    host.openBeside();
    const outer = host.act(authorOf(who));
    const out = host.callCommandAwaiting(id, args, arena, sink);
    host.endAct(outer);
    host.endOpenBeside();
    if (out == .now and out.now == .ok) if (doc_path) |p| note(host, who, p, id, args);
    return out;
}

/// Note step `id` in `who`'s session on `path`, for its tape.
fn note(host: *sdk.Host, who: u32, path: []const u8, id: []const u8, args: []const u8) void {
    for (held.items) |*h| {
        if (h.who != who or !eql(h.path, path)) continue;
        if (h.rec) |*rec| rec.note(id, args, host.last_showing_ms) catch {};
    }
}

/// An `agent.call` whose command answers later: who to answer, and the step to note then. Owns
/// its strings, in the host's allocator. Let go of with the plugin's sinks if the plugin goes
/// first, which leaks it once, at unload.
const LaterCall = struct {
    to: Reply,
    id: []u8,
    args: []u8,
    path: ?[]u8,

    fn done(ctx: *anyopaque, outcome: sdk.Host.CommandOutcome) void {
        const self: *LaterCall = @ptrCast(@alignCast(ctx));
        const host = the_host orelse return;
        if (outcome == .ok) if (self.path) |p| note(host, self.to.who, p, self.id, self.args);
        answerOutcome(host, self.to, outcome);
        self.free(host.allocator);
    }

    fn free(self: *LaterCall, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        gpa.free(self.args);
        if (self.path) |p| gpa.free(p);
        gpa.destroy(self);
    }
};

/// What the person reads for an MCP client's name: "Claude" for Claude's clients
/// ("claude-code", "claude-ai"), else the name as given.
fn clientLabel(client: []const u8) []const u8 {
    return if (std.ascii.startsWithIgnoreCase(client, "claude")) "Claude" else client;
}

/// Undo and redo (`fizzy.undo`, `pixi.redo`, ...) take no document: they act on the active one.
/// When that is not one `who` works on, it is the person's, and an agent's undo would
/// take back their steps: answers its path, to refuse with. Until undo takes a `path`
/// (`plans/SHARED_HISTORY_PLAN.md`, step 5), an agent undoes only its own document, and only
/// while it is the active one.
fn undoesAnother(host: *sdk.Host, who: u32, id: []const u8) ?[]const u8 {
    const action = id[if (std.mem.lastIndexOfScalar(u8, id, '.')) |dot| dot + 1 else 0..];
    if (!eql(action, "undo") and !eql(action, "redo")) return null;
    const doc = host.activeDoc() orelse return null;
    const path = doc.owner.documentPath(doc);
    for (held.items) |h| if (h.who == who and eql(h.path, path)) return null;
    return path;
}

/// `who`'s session on `doc`: the one it has, or a new one, recorded from now on and
/// shown beside the person (`OpenOptions.beside`), who keeps the pane they are in.
fn session(host: *sdk.Host, who: u32, doc: sdk.DocHandle, label: []const u8) !*Held {
    const doc_path = doc.owner.documentPath(doc);
    for (held.items) |*h| if (h.who == who and eql(h.path, doc_path)) return h;
    const path = try host.allocator.dupe(u8, doc_path);
    errdefer host.allocator.free(path);
    const unix_s: i64 = @intCast(@divTrunc(std.Io.Clock.real.now(dvui.io).nanoseconds, std.time.ns_per_s));
    const rec = Recording.start(host.allocator, doc, path, label, unix_s) catch |err| blk: {
        std.log.info("agent: {s} is worked on but not recorded: {t}", .{ path, err });
        break :blk null;
    };
    try held.append(host.allocator, .{ .who = who, .path = path, .rec = rec });
    _ = host.openFile(.{ .path = path, .beside = true }) catch {};
    return &held.items[held.items.len - 1];
}

/// The open document a command is about to work on: the one its `path` argument names, or else
/// the active one, when the command is that document's owner's (`<owner>.<action>`). Another
/// plugin's command naming it (`fizzy.openFiles`) does not work on it.
fn target(host: *sdk.Host, id: []const u8, args: [:0]const u8, arena: std.mem.Allocator) ?sdk.DocHandle {
    const named = if (parse(struct { path: []const u8 = "" }, arena, args)) |a| a.path else "";
    const doc = (if (named.len > 0) host.docFromPath(named) else host.activeDoc()) orelse return null;
    const dot = std.mem.indexOfScalar(u8, id, '.') orelse return null;
    return if (eql(doc.owner.id, id[0..dot])) doc else null;
}

/// `agent.release`: let go of claim `claim_id`, or end the caller's session on `path`, or with
/// neither every one of the caller's.
pub fn release(host: *sdk.Host, to: Reply, arena: std.mem.Allocator, claim_id: u32, path: []const u8) void {
    var tapes: std.ArrayListUnmanaged([]const u8) = .empty;
    var i: usize = 0;
    while (i < held.items.len) {
        const h = &held.items[i];
        const this = h.who == to.who and if (claim_id != 0) h.claim == claim_id else path.len == 0 or eql(h.path, path);
        if (!this) {
            i += 1;
            continue;
        }
        if (h.claim) |c| host.releaseClaim(c);
        if (finish(host, h)) |t| {
            tapes.append(arena, arena.dupe(u8, t) catch t) catch {};
            host.allocator.free(t);
        }
        host.allocator.free(h.path);
        _ = held.swapRemove(i);
    }
    var w: std.Io.Writer.Allocating = .init(arena);
    std.zon.stringify.serialize(.{ .tapes = tapes.items }, .{ .whitespace = false }, &w.writer) catch {};
    to.send(host, true, w.written());
}

/// Write a held document's session as a tape, if anything was recorded, into `<config>/tapes/`;
/// the recording is done either way. Returns the tape's path, in `host.allocator`.
fn finish(host: *sdk.Host, h: *Held) ?[]u8 {
    var rec = h.rec orelse return null;
    h.rec = null;
    defer rec.deinit();
    if (rec.empty()) return null;
    const plugins = host.plugins_dir orelse return null;
    const config = std.fs.path.dirname(plugins) orelse return null;
    const dir = std.fs.path.join(host.allocator, &.{ config, "tapes" }) catch return null;
    defer host.allocator.free(dir);
    return rec.write(dir, dvui.io) catch |err| {
        std.log.err("agent: could not write the tape for {s}: {t}", .{ h.path, err });
        return null;
    };
}

fn automation(host: *sdk.Host) ?*Automation {
    return host.getServiceTyped(Automation);
}

/// One socket request: `hello` and `commands.list` are the socket's own, a snapshot and settling
/// are answered here as the bridge reads them, and every other tool is its `agent.*` command,
/// called as this connection (`connAuthor`) through `Host.callCommandAwaiting`, as the control
/// server calls it.
fn handle(host: *sdk.Host, req: *Server.Request) void {
    var arena_state: std.heap.ArenaAllocator = .init(host.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tool = req.tool;

    if (eql(tool, "hello")) {
        const source = arena.dupeSentinel(u8, req.args, 0) catch return req.answer(the_server.?, false, "out of memory");
        // The client's name, as its MCP client gave it ("claude-code"): the label its steps carry.
        if (parse(struct { client: []const u8 = "" }, arena, source)) |a| if (a.client.len > 0) {
            if (host.allocator.dupe(u8, clientLabel(a.client))) |l| {
                if (labels.fetchPut(host.allocator, req.conn, l) catch null) |old| host.allocator.free(old.value);
            } else |_| {}
        };
    }
    const to: Reply = .{ .who = connAuthor(host, req.conn), .to = .{ .req = req } };
    const source = arena.dupeSentinel(u8, req.args, 0) catch return to.send(host, false, "out of memory");

    if (eql(tool, "hello")) {
        // The executable this fizzy runs from: the bridge compares it across an app build to tell
        // whether fizzy will restart into a new one (`fizzy_build` on an app's repo).
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = std.process.executablePath(dvui.io, &buf) catch 0;
        var w: std.Io.Writer.Allocating = .init(arena);
        std.zon.stringify.serialize(.{
            .app = "fizzy",
            .executable = buf[0..n],
            .tools = .{ "commands.list", "commands.call", "ui.snapshot", "ui.capture", "ui.settled", "ui.act", "ui.run", "plugin.build", "tape.play", "tape.outcome", "profile.report", "doc.claim", "doc.release" },
        }, .{ .whitespace = false }, &w.writer) catch return to.send(host, false, "out of memory");
        return to.send(host, true, w.written());
    }
    if (eql(tool, "commands.list")) {
        const a = parse(struct { prefix: []const u8 = "" }, arena, source) orelse
            return to.send(host, false, "commands.list takes .{ .prefix = \"<a plugin's id and a dot, or a command's id>\" }");
        return listCommands(host, to, arena, a.prefix);
    }
    if (eql(tool, "ui.snapshot")) {
        const auto = automation(host) orelse return to.send(host, false, "this app offers no automation service");
        return wait(host, to, .{ .snapshot = auto.snapshot() });
    }
    if (eql(tool, "ui.settled")) {
        const auto = automation(host) orelse return to.send(host, false, "this app offers no automation service");
        const Args = struct { timeout_ms: u32 = 5000 };
        const a = parse(Args, arena, source) orelse Args{};
        if (auto.settled()) return to.send(host, true, "true");
        return wait(host, to, .{ .settled = now() + ms(a.timeout_ms) });
    }

    const routes = [_][2][]const u8{
        .{ "commands.call", "agent.call" },
        .{ "ui.capture", "agent.capture" },
        .{ "ui.act", "agent.act" },
        .{ "ui.run", "agent.run" },
        .{ "plugin.build", "agent.build" },
        .{ "tape.play", "agent.tape" },
        .{ "tape.outcome", "agent.tapeOutcome" },
        .{ "profile.report", "agent.profile" },
        .{ "doc.claim", "agent.claim" },
        .{ "doc.release", "agent.release" },
    };
    const id = for (routes) |r| {
        if (eql(r[0], tool)) break r[1];
    } else return to.send(host, false, "no such tool (hello lists them)");
    // `tape.play` sends the tape itself; its command takes it as `.tape`.
    const args = if (eql(tool, "tape.play"))
        std.fmt.allocPrint(arena, ".{{ .tape = \"{f}\" }}", .{std.zig.fmtString(req.args)}) catch return to.send(host, false, "out of memory")
    else
        req.args;
    const outer = host.act(authorOf(to.who));
    const out = host.callCommandAwaiting(id, args, arena, .{ .ctx = req, .done = answerRequest, .owner = owner });
    host.endAct(outer);
    switch (out) {
        .now => |o| answerOutcome(host, to, o),
        .later => {},
    }
}

/// A socket request's command answering in a later frame (`CallSink.done`).
fn answerRequest(ctx: *anyopaque, outcome: sdk.Host.CommandOutcome) void {
    const req: *Server.Request = @ptrCast(@alignCast(ctx));
    const host = the_host orelse return;
    answerOutcome(host, .{ .who = connAuthor(host, req.conn), .to = .{ .req = req } }, outcome);
}

fn answerOutcome(host: *sdk.Host, to: Reply, outcome: sdk.Host.CommandOutcome) void {
    switch (outcome) {
        .ok => |r| to.send(host, true, r orelse "null"),
        .unknown => to.send(host, false, "no command by that id (commands.list)"),
        .disabled => to.send(host, false, "that command is not enabled now"),
        .bad_args, .failed => |m| to.send(host, false, m),
    }
}

/// `agent.call`: command `id` with `args`, as the caller's step.
pub fn call(host: *sdk.Host, to: Reply, arena: std.mem.Allocator, id: []const u8, args: []const u8) void {
    const gpa = host.allocator;
    const pending = gpa.create(LaterCall) catch return to.send(host, false, "out of memory");
    pending.* = .{ .to = to, .id = gpa.dupe(u8, id) catch "", .args = gpa.dupe(u8, args) catch "", .path = null };
    // The document it works on, for the note when it answers later: the session `agentCallAwaiting`
    // finds or makes for it.
    if (target(host, id, arena.dupeSentinel(u8, args, 0) catch "", arena)) |doc| pending.path = gpa.dupe(u8, doc.owner.documentPath(doc)) catch null;
    switch (agentCallAwaiting(host, to.who, id, args, arena, .{ .ctx = pending, .done = LaterCall.done, .owner = owner })) {
        .now => |o| {
            pending.free(gpa);
            answerOutcome(host, to, o);
        },
        .later => {},
    }
}

/// `agent.capture`: a picture of a window, written raw to `path`.
pub fn capture(host: *sdk.Host, to: Reply, path: []const u8, window: []const u8) void {
    const auto = automation(host) orelse return to.send(host, false, "this app offers no automation service");
    if (!std.fs.path.isAbsolute(path)) return to.send(host, false, "give the picture's path as an absolute path");
    const owned = host.allocator.dupe(u8, path) catch return to.send(host, false, "out of memory");
    wait(host, to, .{ .capture = .{ .ticket = auto.capture(window), .path = owned } });
}

/// `agent.build`: build a plugin, wait for it to reload, run its check (`Build.zig`).
pub fn build(host: *sdk.Host, to: Reply, source: [:0]const u8) void {
    const plugins = host.getServiceTyped(sdk.services.plugins.Api) orelse return to.send(host, false, "this app offers no plugins service (fizzy's SDK 0.2.22 or later)");
    const b = Build.start(host.allocator, host, plugins, to.who, source) catch |err| return to.send(host, false, switch (err) {
        error.BadArguments => "agent.build takes .{ .path = \"<plugin directory>\", .optimize, .check = .{ <agent.run steps> }, .timeout_ms }",
        error.PathNotAbsolute => "give the plugin's directory as an absolute path",
        error.NoPluginZon => "no plugin.zig.zon with an id in that directory",
        error.CannotBuildItself => "the agent plugin cannot rebuild itself: its reload would end this request",
        else => @errorName(err),
    });
    wait(host, to, .{ .build = b });
}

/// `agent.tape`: play a live tape as the caller.
pub fn playTape(host: *sdk.Host, to: Reply, arena: std.mem.Allocator, bytes: []const u8) void {
    const auto = automation(host) orelse return to.send(host, false, "this app offers no automation service");
    switch (auto.playAs(bytes, authorOf(to.who))) {
        .started => |t| to.send(host, true, std.fmt.allocPrint(arena, ".{{ .ticket = {d} }}", .{@backingInt(t)}) catch "?"),
        .busy => to.send(host, false, "something else is driving fizzy: a tape or a demo"),
        .invalid => |why| to.send(host, false, why),
    }
}

/// `agent.tapeOutcome`: how the tape `ticket` names ended, or that it plays on.
pub fn tapeOutcome(host: *sdk.Host, to: Reply, ticket: u32) void {
    const auto = automation(host) orelse return to.send(host, false, "this app offers no automation service");
    var buf: [64]u8 = undefined;
    to.send(host, true, outcomeText(&buf, auto.outcome(@fromBackingInt(@intCast(ticket)))));
}

/// `agent.profile`: the profiler's report after `ms_` of frames. `drive`: ask for every frame, to
/// measure what drawing costs; else only the frames fizzy draws on its own are measured
/// (`measure.zig`). `startup`: also when the app's start reached each phase.
pub fn profile(host: *sdk.Host, to: Reply, ms_: u32, drive: bool, startup: bool) void {
    // A window of averages is half a second: ask for a little more than was asked.
    core.profile.want(ms_ + 600);
    wait(host, to, .{ .profile = .{ .until = now() + ms(ms_ + 600), .drive = drive, .startup = startup } });
}

fn wait(host: *sdk.Host, to: Reply, until: @FieldType(Waiting, "until")) void {
    waiting.append(host.allocator, .{ .to = to, .until = until }) catch to.send(host, false, "out of memory");
}

/// `image` as the bridge reads it: `"FZPX"`, its width and height (little-endian `u32`s), then its
/// pixels as drawn. No encode: that is the bridge's, in its own process, not this frame's.
fn writeRaw(path: []const u8, image: Automation.Image) !void {
    const io = dvui.io;
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var head: [12]u8 = undefined;
    head[0..4].* = "FZPX".*;
    std.mem.writeInt(u32, head[4..8], image.width, .little);
    std.mem.writeInt(u32, head[8..12], image.height, .little);
    var buf: [64 * 1024]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.writeAll(&head);
    try w.interface.writeAll(image.pixels);
    try w.end();
}

/// Not yet: look again next frame, and make sure there is one. What `w` waits on is written at
/// the end of a frame (a snapshot) or decided by one (a tape's last op), and this runs at the
/// start of the next, which an idle app would never draw.
fn later(host: *sdk.Host) bool {
    host.refresh();
    return false;
}

/// True once `w` is answered.
fn check(host: *sdk.Host, w: *Waiting) bool {
    const auto = automation(host) orelse {
        w.to.send(host, false, "the automation service went away");
        return true;
    };
    switch (w.until) {
        .snapshot => |t| {
            const text = auto.snapshotText(t) orelse return later(host);
            w.to.send(host, true, text);
            return true;
        },
        .capture => |c| {
            const image = auto.captureImage(c.ticket) orelse return later(host);
            defer host.allocator.free(c.path);
            if (image.width == 0) {
                w.to.send(host, false, "no window has that tag: ui.snapshot lists them (.role = \"window\")");
                return true;
            }
            // Raw, as fizzy drew it: the bridge, in its own process, scales and encodes it.
            writeRaw(c.path, image) catch |err| {
                w.to.send(host, false, @errorName(err));
                return true;
            };
            w.to.send(host, true, c.path);
            return true;
        },
        .settled => |deadline| {
            if (auto.settled()) {
                w.to.send(host, true, "true");
                return true;
            }
            if (now() < deadline) return false;
            w.to.send(host, true, "false");
            return true;
        },
        .build => |b| {
            const plugins = host.getServiceTyped(sdk.services.plugins.Api) orelse {
                w.to.send(host, false, "the plugins service went away");
                b.deinit();
                return true;
            };
            const report = b.advance(host, plugins, auto) orelse return false;
            w.to.send(host, true, report);
            b.deinit();
            return true;
        },
        .run => |r| {
            const report = r.advance(host, auto) orelse return false;
            w.to.send(host, true, report);
            r.deinit(host.allocator);
            return true;
        },
        .profile => |wait_p| {
            if (now() < wait_p.until) {
                // Driving, every frame, as the profiler window's "Continuous" does; else one frame
                // when the window ends, and whatever fizzy draws meanwhile.
                if (wait_p.drive) return later(host);
                measure.wakeAt(wait_p.until, now());
                return false;
            }
            const p = core.profile.current() orelse {
                w.to.send(host, false, "no profiler in this app");
                return true;
            };
            var out: std.Io.Writer.Allocating = .init(host.allocator);
            defer out.deinit();
            core.profile.report(p, &out.writer, .{ .startup = wait_p.startup }) catch {};
            w.to.send(host, true, out.written());
            return true;
        },
    }
}

/// `agent.run`: a script, run across frames, answered with one report (`Run.zig`).
pub fn run(host: *sdk.Host, to: Reply, source: [:0]const u8) void {
    const auto = automation(host) orelse return to.send(host, false, "this app offers no automation service");
    const r = Run.init(host.allocator, to.who, source) catch |err| return to.send(host, false, switch (err) {
        error.BadScript => "agent.run takes .{ .steps = .{ .{ .click = .{ .tag = \"...\" } }, .{ .call = .{ .id, .args } }, .{ .expect = .{ .tag } }, .{ .settle = .{} }, .{ .screen = .{} }, .{ .profile = .{ .ms } }, ... }, .timeout_ms }",
        error.OutOfMemory => "out of memory",
    });
    if (r.advance(host, auto)) |report| {
        to.send(host, true, report);
        return r.deinit(host.allocator);
    }
    wait(host, to, .{ .run = r });
}

/// `agent.act`: input as a live tape, then the screen unless `snapshot` is false. A run of its
/// steps, with `screen` after.
pub fn act(host: *sdk.Host, to: Reply, arena: std.mem.Allocator, source: [:0]const u8) void {
    const Args = struct { steps: []const Run.Step, snapshot: bool = true, timeout_ms: u32 = 10_000 };
    const a = parse(Args, arena, source) orelse return to.send(host, false,
        \\agent.act takes .{ .steps = .{ .{ .click = .{ .tag = "..." } }, .{ .type = "..." }, .{ .key = "mod+s" }, ... }, .snapshot = true }
    );
    var steps: std.ArrayListUnmanaged(Run.Step) = .empty;
    steps.appendSlice(arena, a.steps) catch return to.send(host, false, "out of memory");
    if (a.snapshot) steps.append(arena, .{ .screen = .{} }) catch return to.send(host, false, "out of memory");
    var out: std.Io.Writer.Allocating = .init(arena);
    // `Run.Step` nests (a `compare` holds steps): the serializer is given a depth to stop at.
    std.zon.stringify.serializeMaxDepth(Run.Args{ .steps = steps.items, .timeout_ms = a.timeout_ms }, .{ .emit_default_optional_fields = false }, &out.writer, 32) catch
        return to.send(host, false, "out of memory");
    const zon = arena.dupeSentinel(u8, out.written(), 0) catch return to.send(host, false, "out of memory");
    run(host, to, zon);
}

fn outcomeText(buf: []u8, o: Automation.Outcome) []const u8 {
    return switch (o) {
        .playing => ".playing",
        .finished => ".finished",
        .unknown => ".unknown",
        .interrupted => |n| std.fmt.bufPrint(buf, ".{{ .interrupted_before_step = {d} }}", .{n}) catch "?",
        .timed_out => |n| std.fmt.bufPrint(buf, ".{{ .wait_timed_out_at_step = {d} }}", .{n}) catch "?",
        .stopped => |n| std.fmt.bufPrint(buf, ".{{ .stopped_before_step = {d} }}", .{n}) catch "?",
    };
}

/// With no `prefix`, an index, a line per command: its id, its title and whether it can run, which is all an
/// agent needs to find one, and a small part of the whole (pixi alone offers some eighty). With
/// one, the commands whose ids start with it, parameters too.
fn listCommands(host: *sdk.Host, to: Reply, arena: std.mem.Allocator, prefix: []const u8) void {
    const ParamOut = struct {
        key: []const u8,
        label: []const u8,
        description: []const u8,
        kind: []const u8,
        required: bool,
        default: ?[]const u8 = null,
        choices: ?[]const []const u8 = null,
        min: ?f64 = null,
        max: ?f64 = null,
    };
    const CommandOut = struct {
        id: []const u8,
        title: []const u8,
        enabled: bool,
        params: []const ParamOut,
    };
    var w: std.Io.Writer.Allocating = .init(arena);
    var out: std.ArrayListUnmanaged(CommandOut) = .empty;
    for (0..host.commandCount()) |i| {
        const c = host.commandAt(i) orelse continue;
        if (prefix.len == 0) {
            w.writer.print("{s}  {s}{s}\n", .{ c.id, c.title, if (host.commandEnabled(c.id)) "" else "  (not now)" }) catch {};
            continue;
        }
        if (!std.mem.startsWith(u8, c.id, prefix)) continue;
        var params: std.ArrayListUnmanaged(ParamOut) = .empty;
        for (c.params) |p| {
            var po: ParamOut = .{ .key = p.key, .label = p.label, .description = p.description, .kind = @tagName(p.kind), .required = p.required, .default = p.default };
            switch (p.kind) {
                .enumeration => |e| po.choices = e.choices,
                .int => |k| {
                    po.min = @floatFromInt(k.min);
                    po.max = @floatFromInt(k.max);
                },
                .float => |k| {
                    po.min = k.min;
                    po.max = k.max;
                },
                else => {},
            }
            params.append(arena, po) catch {};
        }
        out.append(arena, .{ .id = c.id, .title = c.title, .enabled = host.commandEnabled(c.id), .params = params.items }) catch {};
    }
    if (prefix.len > 0) std.zon.stringify.serialize(out.items, .{ .emit_default_optional_fields = false }, &w.writer) catch {};
    to.send(host, true, w.written());
}

fn parse(comptime T: type, arena: std.mem.Allocator, source: [:0]const u8) ?T {
    var diag: std.zon.parse.Diagnostics = undefined;
    if (source.len == 0) return std.zon.parse.fromSlice(T, .{ .gpa = arena, .arena = arena, .source = ".{}", .diagnostics = &diag }) catch null;
    return std.zon.parse.fromSlice(T, .{ .gpa = arena, .arena = arena, .source = source, .diagnostics = &diag, .ignore_unknown_fields = true }) catch null;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
