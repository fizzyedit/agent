//! The agent's tools as commands (`plans/AGENTS_ANYWHERE_PLAN.md`, step 1): `agent.run`,
//! `agent.act`, `agent.build`, … What is the app's already — the screen, settling — is
//! `fizzy.screen` and `fizzy.settled`; these are what only an agent wants. Being commands, they
//! are served wherever commands are: fizzy's control server (`/mcp`, `/commands`, its OpenAPI),
//! the palette's internal list, another plugin, the socket `fizzy-mcp` speaks (`tools.handle`).
//!
//! Each is the caller's step (`tools.caller`): who acts when it runs, the control server's client
//! or the socket's connection. Each answers through its ticket (`Command.Call.later`): now, when
//! it can, or from a later frame (`tools.frame`), as a script plays out or a build reloads.
const std = @import("std");
const sdk = @import("fizzy_sdk");
const tools = @import("tools.zig");
const Run = @import("Run.zig");

const Arg = sdk.Command.Arg;
const Call = sdk.Command.Call;

const CallArgs = sdk.Command.Params(struct {
    id: Arg([]const u8, .{ .description = "The command to run, by id (fizzy's /commands, or tools/list, lists them)." }),
    args: Arg([]const u8, .{ .description = "Its arguments, as ZON: `.{ .path = \"/a.png\", .layer = 0 }`." }) = .init(""),
});

const RunArgs = sdk.Command.Params(struct {
    steps: Arg([]const Run.Step, .{ .description = "The steps, in order. Each is one of: click, double_click, move (a point: .tag, or .x/.y in physical pixels, or both; .fx/.fy as fractions of the tagged widget), stroke (.tag, .points, .ms, or .grid and .cells), type (text), key (a chord: \"mod+s\"), command (an id, no arguments), wait_for / wait_gone (a tag), call (.id, .args as ZON), expect (.tag, .shown), settle, screen, profile (.ms, .drive), compare (.ms, .drive, .steps)." }),
    timeout_ms: Arg(u32, .{ .description = "How long a wait in the steps, or settling, holds before the run fails." }) = .init(10_000),
});

const ActArgs = sdk.Command.Params(struct {
    steps: Arg([]const Run.Step, .{ .description = "Input to play as a person's: click, double_click, move, stroke, type, key, command, wait_for, wait_gone (agent.run's steps)." }),
    snapshot: Arg(bool, .{ .description = "Answer with the screen after, as fizzy.screen does." }) = .init(true),
    timeout_ms: Arg(u32, .{ .description = "How long a wait holds before it fails." }) = .init(10_000),
});

const BuildArgs = sdk.Command.Params(struct {
    path: Arg([]const u8, .{ .description = "The plugin's directory (its plugin.zig.zon), or fizzy's own repository, as an absolute path." }),
    optimize: Arg([]const u8, .{ .description = "`-Doptimize`, as zig spells it (\"ReleaseFast\"); empty for the plugin's default." }) = .init(""),
    check: Arg([]const Run.Step, .{ .description = "Steps to run once it has reloaded (agent.run's), checking what came back." }) = .init(&.{}),
    timeout_ms: Arg(u32, .{ .description = "How long the build and reload may take." }) = .init(120_000),
});

const CaptureArgs = sdk.Command.Params(struct {
    path: Arg([]const u8, .{ .description = "Where to write the picture, as an absolute path: \"FZPX\", its width and height as little-endian u32s, then premultiplied RGBA rows." }),
    window: Arg([]const u8, .{ .description = "A window's tag (fizzy.screen lists them), \"*\" for every window, or empty for the main one." }) = .init(""),
});

const TapeArgs = sdk.Command.Params(struct {
    tape: Arg([]const u8, .{ .description = "A live tape, as ZON (docs/AUTOMATION.md)." }),
});

const TapeOutcomeArgs = sdk.Command.Params(struct {
    ticket: Arg(u32, .{ .description = "The ticket agent.tape answered." }),
});

const ProfileArgs = sdk.Command.Params(struct {
    ms: Arg(u32, .{ .description = "How long to measure, in milliseconds." }) = .init(1000),
    drive: Arg(bool, .{ .description = "Ask for every frame, to measure what drawing costs; else only the frames fizzy draws on its own." }) = .init(false),
    startup: Arg(bool, .{ .description = "Also say when the app's start reached each phase." }) = .init(false),
});

const ClaimArgs = sdk.Command.Params(struct {
    path: Arg([]const u8, .{ .description = "The open document to hold." }),
    label: Arg([]const u8, .{ .description = "What the person reads while you hold it; empty for your name." }) = .init(""),
});

const ReleaseArgs = sdk.Command.Params(struct {
    claim: Arg(u32, .{ .description = "The claim to let go of, as agent.claim answered; 0 for none." }) = .init(0),
    path: Arg([]const u8, .{ .description = "A document to end your session on; with no claim and no path, every one." }) = .init(""),
});

pub fn register(host: *sdk.Host, owner: *sdk.Plugin) !void {
    const all = [_]sdk.Command{
        .{ .id = "agent.call", .title = "Run a Command as the Agent's Step", .params = CallArgs.params, .runWith = CallArgs.bind(call) },
        .{ .id = "agent.run", .title = "Run a Script", .params = RunArgs.params, .runWith = script(.run) },
        .{ .id = "agent.act", .title = "Act as a Person Would", .params = ActArgs.params, .runWith = script(.act) },
        .{ .id = "agent.build", .title = "Build, Reload and Check a Plugin", .params = BuildArgs.params, .runWith = script(.build) },
        .{ .id = "agent.capture", .title = "Picture a Window", .params = CaptureArgs.params, .runWith = CaptureArgs.bind(capture) },
        .{ .id = "agent.tape", .title = "Play a Tape", .params = TapeArgs.params, .runWith = TapeArgs.bind(tape) },
        .{ .id = "agent.tapeOutcome", .title = "How a Tape Ended", .params = TapeOutcomeArgs.params, .runWith = TapeOutcomeArgs.bind(tapeOutcome) },
        .{ .id = "agent.profile", .title = "Measure Frames", .params = ProfileArgs.params, .runWith = ProfileArgs.bind(profile) },
        .{ .id = "agent.claim", .title = "Hold a Document", .params = ClaimArgs.params, .runWith = ClaimArgs.bind(claim) },
        .{ .id = "agent.release", .title = "Let Go of Documents", .params = ReleaseArgs.params, .runWith = ReleaseArgs.bind(release) },
    };
    for (all) |c| {
        var cmd = c;
        cmd.owner = owner;
        cmd.visibility = .internal;
        try host.registerCommand(cmd);
    }
}

/// The caller, and where the answer goes: the call's ticket, answered now or later.
fn replyFor(call_: *Call) tools.Reply {
    const host = tools.the_host.?;
    return .{ .who = tools.caller(host), .to = .{ .ticket = call_.later() } };
}

fn call(_: *anyopaque, a: CallArgs.Args, c: *Call) !void {
    tools.call(tools.the_host.?, replyFor(c), c.arena, a.id, a.args);
}

/// A command whose arguments the agent's own code reads (a script's steps): checked against its
/// parameters first, so a mismatch says where, then handed over as they came.
fn script(comptime which: enum { run, act, build }) *const fn (*anyopaque, *Call) anyerror!void {
    return &struct {
        fn runWith(_: *anyopaque, c: *Call) anyerror!void {
            _ = try switch (which) {
                .run => RunArgs.parse(c),
                .act => ActArgs.parse(c),
                .build => BuildArgs.parse(c),
            };
            const host = tools.the_host.?;
            const text = std.mem.trim(u8, c.args, " \t\r\n");
            const source = try c.arena.dupeSentinel(u8, if (text.len == 0) ".{}" else text, 0);
            const to = replyFor(c);
            switch (which) {
                .run => tools.run(host, to, source),
                .act => tools.act(host, to, c.arena, source),
                .build => tools.build(host, to, source),
            }
        }
    }.runWith;
}

fn capture(_: *anyopaque, a: CaptureArgs.Args, c: *Call) !void {
    tools.capture(tools.the_host.?, replyFor(c), a.path, a.window);
}

fn tape(_: *anyopaque, a: TapeArgs.Args, c: *Call) !void {
    tools.playTape(tools.the_host.?, replyFor(c), c.arena, a.tape);
}

fn tapeOutcome(_: *anyopaque, a: TapeOutcomeArgs.Args, c: *Call) !void {
    tools.tapeOutcome(tools.the_host.?, replyFor(c), a.ticket);
}

fn profile(_: *anyopaque, a: ProfileArgs.Args, c: *Call) !void {
    tools.profile(tools.the_host.?, replyFor(c), a.ms, a.drive, a.startup);
}

fn claim(_: *anyopaque, a: ClaimArgs.Args, c: *Call) !void {
    const host = tools.the_host.?;
    const to = replyFor(c);
    tools.claim(host, to, a.path, if (a.label.len > 0) a.label else tools.authorOf(to.who).label);
}

fn release(_: *anyopaque, a: ReleaseArgs.Args, c: *Call) !void {
    tools.release(tools.the_host.?, replyFor(c), c.arena, a.claim, a.path);
}
