# agent

A fizzy plugin that lets an AI agent drive fizzy the way a person does, and `fizzy-mcp`, the MCP
server an agent (Claude Code, Codex, Grok's CLI, any MCP client) runs to reach it.

- **Every command is a tool.** Plugins' commands, with their parameters, are each plugin's API
  to an agent: `fizzy_commands` lists them, and `fizzy_call` runs one with arguments.
- **The screen as text.** `fizzy_screen` answers what is drawn: one line per widget worth
  naming, with its role, name, tag and rect, read from the frame dvui just drew.
- **Scripts in one call.** `fizzy_run` runs a list of steps (input, commands with arguments,
  waits, expectations, settling, the screen, the profiler) across fizzy's frames and answers one
  report, with the step that failed and why. Turns are what an agent's iteration costs; a check
  that took six calls takes one.
- **Build, reload, check: one call.** `fizzy_build` builds a plugin's directory, answers
  compile errors as data (file, line, column, message), waits for fizzy to reload the rebuilt
  binary, and runs a `fizzy_run` script against it. A warm loop is about a second.
- **The build loop in one call.** `fizzy_build` builds a plugin, answers the compiler's errors as
  file, line and message, waits for fizzy to reload it, and runs a check script on what came
  back. Given fizzy's own repo instead, it builds fizzy and waits for the running fizzy to restart
  into the new executable (Settings > Restart when rebuilt), every open document kept, then runs
  the check there. The bridge does that half, since the plugin goes with the old fizzy.
- **Input as a person's.** `fizzy_act` clicks, types and presses keys through the same widgets a
  person uses, as a live tape. Everything shows on screen and lands in undo, and a person's own
  click stops it.
- **The profiler on request.** `fizzy_profile` measures for a while and answers fps, frame
  work, and time per plugin and per scope. Use it instead of adding logging.

Nothing here is a back door: an agent can do what a person at the keyboard can, and no more.

## Use it

```sh
zig build                      # the plugin, into fizzy's plugins dir; fizzy-mcp into zig-out/bin
claude mcp add fizzy -- "$PWD/zig-out/bin/fizzy-mcp"
```

Enable **Agent** in fizzy's plugin settings. For a sandbox beside your own fizzy, give both the
same profile:

```sh
FIZZY_PROFILE=~/fizzy-sandbox zig build
fizzy --profile ~/fizzy-sandbox
claude mcp add fizzy-sandbox -- "$PWD/zig-out/bin/fizzy-mcp" --profile ~/fizzy-sandbox
```

fizzy need not be running when the agent starts. The bridge connects on the first call, and
again after fizzy restarts.

## How it fits together

```
agent ⇄ MCP (JSON-RPC, stdio) ⇄ fizzy-mcp ⇄ Unix socket (ZON lines) ⇄ agent plugin ⇄ fizzy
```

- `plugin.zig`: on load, opens a Unix socket in the plugin's directory and writes
  `connection.zon` beside it (the socket's path and a fresh token, readable by this user only).
- `src/Server.zig`: the socket's thread. It checks the token on `hello`, hands each request to
  the UI thread, and wakes the app to answer it.
- `src/tools.zig`: the tools, answered on the UI thread in `beginFrame`. Some answer in the same
  frame; the rest (a snapshot, a tape, a measurement) wait across frames and ask for each frame
  they need.
- `bridge/main.zig`: `fizzy-mcp`, standard library only. It turns MCP calls into the plugin's
  requests, and JSON arguments into ZON.

Desktop only: a wasm side module cannot open a socket. On Windows, `std`'s Unix sockets are
untested here.
