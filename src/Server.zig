//! The plugin's end of the socket `fizzy-mcp` talks to: a Unix socket only this user can open,
//! behind a token, served by one thread of its own. Nothing here touches fizzy: a request is
//! handed to the UI thread (`take`, from the plugin's `beginFrame`), and the connection's thread
//! waits until the answer is set (`Request.answer`), then writes it back.
//!
//! The wire format is one ZON value per line, both ways — `Wire.Request` in, `Wire.Response`
//! out — so the strings inside are escaped and a line is a message. A connection opens with
//! `hello` carrying the token from `connection.zon`, which the plugin writes beside the socket for
//! a client to find; anything else first and the connection is closed.
//!
//! Each connection has a thread of its own, so several clients are served at once: an agent in
//! the chat panel holds its connection for the whole session, and an agent in a terminal must not
//! wait for it. One request is in flight per connection (an agent waits for each answer anyway),
//! and the UI thread answers them in the order they arrive.
const Server = @This();

const std = @import("std");
const Io = std.Io;

gpa: std.mem.Allocator,
io: Io,
socket_path: []u8,
token: [32]u8,
/// Wakes the app so its next frame drains the queue (`Host.refresh`, safe from any thread).
wake: *const fn () void,
thread: ?std.Thread = null,
listener: ?Io.net.Server = null,
/// The connections being served, under `lock`, so `stop` can end their reads and wait for them.
conns: std.ArrayListUnmanaged(*Conn) = .empty,
stopping: std.atomic.Value(bool) = .init(false),
/// Requests waiting for the UI thread, under `lock`.
lock: Io.Mutex = .init,
pending: std.ArrayListUnmanaged(*Request) = .empty,

const Conn = struct {
    stream: Io.net.Stream,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
};

pub const Wire = struct {
    pub const Request = struct {
        id: u64,
        tool: []const u8,
        /// The tool's arguments as ZON text; empty for none.
        args: []const u8 = "",
    };
    pub const Response = struct {
        id: u64,
        /// The result as ZON text, when the tool succeeded.
        ok: ?[]const u8 = null,
        /// Why it did not, in words.
        err: ?[]const u8 = null,
    };
};

/// One request on its way through the UI thread.
pub const Request = struct {
    id: u64,
    tool: []const u8,
    args: []const u8,
    /// Set by the UI thread (`answer`); the connection's thread owns both strings after.
    ok: ?[]u8 = null,
    err: ?[]u8 = null,
    done: Io.Event = .unset,

    /// Answer, from the UI thread: copies `text` with `gpa`, which must be safe across threads.
    pub fn answer(self: *Request, server: *Server, ok: bool, text: []const u8) void {
        const copy = server.gpa.dupe(u8, text) catch null;
        if (ok) self.ok = copy else self.err = copy;
        self.done.set(server.io);
    }
};

pub fn start(self: *Server) !void {
    self.thread = try std.Thread.spawn(.{}, run, .{self});
}

/// Requests the UI thread should answer now. On the UI thread, each frame.
pub fn take(self: *Server, out: *std.ArrayListUnmanaged(*Request)) void {
    self.lock.lockUncancelable(self.io);
    defer self.lock.unlock(self.io);
    out.appendSlice(self.gpa, self.pending.items) catch return;
    self.pending.clearRetainingCapacity();
}

pub fn stop(self: *Server) void {
    self.stopping.store(true, .release);
    // Whatever the UI thread will never answer now, answered: its connection's thread is waiting.
    {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        for (self.pending.items) |r| r.answer(self, false, "fizzy is closing");
        self.pending.clearRetainingCapacity();
        for (self.conns.items) |c| c.stream.shutdown(self.io, .both) catch {};
    }
    // A thread in `accept` wakes when someone connects: be that someone.
    if (Io.net.UnixAddress.init(self.socket_path)) |addr| {
        if (addr.connect(self.io)) |s| s.close(self.io) else |_| {}
    } else |_| {}
    if (self.thread) |t| t.join();
    self.thread = null;
    // No more are accepted: wait for each connection's thread, its read ended above.
    for (self.conns.items) |c| {
        if (c.thread) |t| t.join();
        self.gpa.destroy(c);
    }
    self.conns.deinit(self.gpa);
    if (self.listener) |*l| l.deinit(self.io);
    self.listener = null;
    Io.Dir.deleteFileAbsolute(self.io, self.socket_path) catch {};
    self.pending.deinit(self.gpa);
}

fn run(self: *Server) void {
    Io.Dir.deleteFileAbsolute(self.io, self.socket_path) catch {};
    const addr = Io.net.UnixAddress.init(self.socket_path) catch return;
    self.listener = addr.listen(self.io, .{}) catch |err| {
        std.log.err("agent: could not listen on {s}: {t}", .{ self.socket_path, err });
        return;
    };
    while (!self.stopping.load(.acquire)) {
        const stream = self.listener.?.accept(self.io) catch continue;
        if (self.stopping.load(.acquire)) {
            stream.close(self.io);
            return;
        }
        const conn = self.gpa.create(Conn) catch {
            stream.close(self.io);
            continue;
        };
        conn.* = .{ .stream = stream };
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.reap();
        self.conns.append(self.gpa, conn) catch {
            stream.close(self.io);
            self.gpa.destroy(conn);
            continue;
        };
        conn.thread = std.Thread.spawn(.{}, serveConn, .{ self, conn }) catch {
            _ = self.conns.pop();
            stream.close(self.io);
            self.gpa.destroy(conn);
            continue;
        };
    }
}

fn serveConn(self: *Server, conn: *Conn) void {
    self.serve(conn.stream);
    conn.stream.close(self.io);
    conn.done.store(true, .release);
}

/// Join and free connections whose clients have gone. Under `lock`.
fn reap(self: *Server) void {
    var i: usize = 0;
    while (i < self.conns.items.len) {
        const c = self.conns.items[i];
        if (!c.done.load(.acquire)) {
            i += 1;
            continue;
        }
        if (c.thread) |t| t.join();
        self.gpa.destroy(c);
        _ = self.conns.swapRemove(i);
    }
}

fn serve(self: *Server, stream: Io.net.Stream) void {
    var read_buf: [64 * 1024]u8 = undefined;
    var write_buf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(self.io, &read_buf);
    var writer = stream.writer(self.io, &write_buf);
    var greeted = false;
    while (!self.stopping.load(.acquire)) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch return;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const source = a.dupeZ(u8, std.mem.trimEnd(u8, line, "\r\n")) catch return;
        const wire = std.zon.parse.fromSliceAlloc(Wire.Request, a, source, null, .{ .ignore_unknown_fields = true }) catch {
            respond(&writer.interface, .{ .id = 0, .err = "not a request: one ZON value per line, .{ .id, .tool, .args }" }) catch return;
            continue;
        };
        if (!greeted) {
            if (!std.mem.eql(u8, wire.tool, "hello") or std.mem.indexOf(u8, wire.args, &self.token) == null) {
                respond(&writer.interface, .{ .id = wire.id, .err = "say hello first, with the token from connection.zon" }) catch {};
                return;
            }
            greeted = true;
        }
        var req: Request = .{ .id = wire.id, .tool = wire.tool, .args = wire.args };
        {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            // `stop` answers what is queued before it joins: nothing may be queued after.
            if (self.stopping.load(.acquire)) return;
            self.pending.append(self.gpa, &req) catch return;
        }
        self.wake();
        req.done.wait(self.io) catch return;
        defer if (req.ok) |s| self.gpa.free(s);
        defer if (req.err) |s| self.gpa.free(s);
        respond(&writer.interface, .{ .id = req.id, .ok = req.ok, .err = req.err }) catch return;
    }
}

fn respond(w: *Io.Writer, r: Wire.Response) !void {
    try std.zon.stringify.serialize(r, .{ .whitespace = false, .emit_default_optional_fields = false }, w);
    try w.writeByte('\n');
    try w.flush();
}
