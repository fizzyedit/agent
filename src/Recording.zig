//! A claimed document's session, written as a tape when the claim ends: a keyframe holding the
//! document as it was when claimed, then each command that changed it, at the time it ran. Played
//! back (`fizzy.demo.playTape`), it shows the work again from the start, with the player's seek
//! and chapters: rewinding to any moment of it is a seek.
//!
//! The keyframe mounts the document at `demo://<name>/<file>`, so a recorded command's path is
//! rewritten to that. A command that names any other absolute path (an export writing a file, a
//! second document) is left out: a replay changes the tape's document and nothing else. Each step
//! takes as long as it goes on showing its work, however long the agent thought, so the tape plays
//! at the pace of the work, one step flowing into the next.
//!
//! Hands other than the agent's work on the document too (the person, another agent). Before each
//! step the document is read again, and when it is not what the last step left, a keyframe of it
//! goes into the tape at that moment, with a chapter naming who: a replay then shows whose work
//! is whose, and a seek back to it lands on the document as that hand left it.
const Recording = @This();

const std = @import("std");
const sdk = @import("fizzy_sdk");
const tape = @import("tape");
const Tape = tape.Tape;

gpa: std.mem.Allocator,
/// The tape's name, which names its mount: `sword-1792345678`.
name: []u8,
/// Who worked, as the claim names them.
label: []u8,
/// The document's path as fizzy has it, and as the tape mounts it.
path: []u8,
mount_path: []u8,
/// Its owner's id: its own path-less commands (`pixi.setColors`) are recorded too.
owner_id: []u8,
/// The document's bytes when it was claimed: the keyframe's file.
bytes: []u8,
/// The document as this session last saw it: as claimed, then as each of its steps left it
/// (`settle`). What differs from it at the next step was done by another hand.
known: []u8,
/// The keyframes after the first: the document as another hand left it.
others: std.ArrayListUnmanaged(Other) = .empty,
ops: std.ArrayListUnmanaged(Tape.Op) = .empty,
/// Strings the ops hold.
strings: std.ArrayListUnmanaged([]u8) = .empty,
last_at: u32 = 0,
/// How long the last step goes on showing its work (`Command.Call.showing_ms`): the next starts
/// as it ends, so a replay flows from one to the next.
last_ms: u32 = 0,

const Other = struct {
    at: u32,
    bytes: []u8,
    /// The chapter's title.
    title: []u8,
};

/// Between a step and the next when the first shows nothing over time: a moment to see it.
const gap_ms = 150;
/// From the keyframe to the first command: time to see where it starts.
const lead_ms = 800;

pub fn start(gpa: std.mem.Allocator, doc: sdk.DocHandle, path: []const u8, label: []const u8, unix_s: i64) !Recording {
    // The name the bytes are written under says their format: the document's own path, or for one
    // never saved (`untitled-1`, which names none) the name Save As offers (`untitled.pixi`). Under
    // its title an untitled document gave no bytes, and its session recorded nothing.
    const bytes_path = try doc.owner.bytesPath(doc, gpa);
    defer gpa.free(bytes_path);
    const bytes = (try doc.owner.documentBytes(doc, bytes_path, gpa)) orelse return error.NotRecordable;
    errdefer gpa.free(bytes);
    const stem = std.fs.path.stem(std.fs.path.basename(path));
    // The tape's copy is opened by that name, so the owner that reads it is the one that wrote it.
    const base = std.fs.path.basename(bytes_path);
    const name = try std.fmt.allocPrint(gpa, "{s}-{d}", .{ stem, unix_s });
    errdefer gpa.free(name);
    for (name) |*c| {
        if (!std.ascii.isAlphanumeric(c.*) and c.* != '-' and c.* != '_') c.* = '-';
    }
    const mount_path = try std.fmt.allocPrint(gpa, "demo://{s}/{s}", .{ name, base });
    errdefer gpa.free(mount_path);
    return .{
        .gpa = gpa,
        .name = name,
        .label = try gpa.dupe(u8, label),
        .path = try gpa.dupe(u8, path),
        .mount_path = mount_path,
        .owner_id = try gpa.dupe(u8, doc.owner.id),
        .bytes = bytes,
        .known = try gpa.dupe(u8, bytes),
    };
}

pub fn deinit(self: *Recording) void {
    for (self.strings.items) |s| self.gpa.free(s);
    self.strings.deinit(self.gpa);
    self.ops.deinit(self.gpa);
    for (self.others.items) |o| {
        self.gpa.free(o.bytes);
        self.gpa.free(o.title);
    }
    self.others.deinit(self.gpa);
    inline for (.{ "name", "label", "path", "mount_path", "owner_id", "bytes", "known" }) |f| self.gpa.free(@field(self, f));
}

/// The document as it is now, in the format `start` recorded it in. In `gpa`.
pub fn current(self: *const Recording, doc: sdk.DocHandle) ![]u8 {
    const bytes_path = try doc.owner.bytesPath(doc, self.gpa);
    defer self.gpa.free(bytes_path);
    return (try doc.owner.documentBytes(doc, bytes_path, self.gpa)) orelse error.NotRecordable;
}

/// Before a step: `now` is the document, and when it is not what the last step left, someone
/// else changed it since. Keyframe it at this moment, credited to `by`.
pub fn adopt(self: *Recording, now: []const u8, by: []const u8) !void {
    if (std.mem.eql(u8, now, self.known)) return;
    const base = std.fs.path.basename(self.mount_path);
    const title = try std.fmt.allocPrint(self.gpa, "{s} changed {s}", .{ by, base });
    errdefer self.gpa.free(title);
    const bytes = try self.gpa.dupe(u8, now);
    errdefer self.gpa.free(bytes);
    const known = try self.gpa.dupe(u8, now);
    errdefer self.gpa.free(known);
    const at = if (self.ops.items.len == 0) lead_ms else self.last_at + @max(self.last_ms, gap_ms);
    try self.others.append(self.gpa, .{ .at = at, .bytes = bytes, .title = title });
    errdefer _ = self.others.pop();
    // The keyframe's own index: the claimed one is 0.
    try self.ops.append(self.gpa, .{ .at = at, .do = .{ .keyframe = @intCast(self.others.items.len) } });
    self.gpa.free(self.known);
    self.known = known;
    self.last_at = at;
    self.last_ms = 0;
}

/// After a step of this session's own: `now` is the document it left, which is not another
/// hand's work at the next.
pub fn settle(self: *Recording, now: []const u8) !void {
    const known = try self.gpa.dupe(u8, now);
    self.gpa.free(self.known);
    self.known = known;
}

/// A command that ran (and succeeded): kept when it acts on this document.
pub fn note(self: *Recording, id: []const u8, args: []const u8, showing_ms: u32) !void {
    const quoted = try std.fmt.allocPrint(self.gpa, "\"{s}\"", .{self.path});
    defer self.gpa.free(quoted);
    const names_it = std.mem.indexOf(u8, args, quoted) != null;
    const own_pathless = std.mem.startsWith(u8, id, self.owner_id) and id.len > self.owner_id.len and
        id[self.owner_id.len] == '.' and std.mem.indexOf(u8, args, ".path") == null;
    if (!names_it and !own_pathless) return;

    const mounted = try std.fmt.allocPrint(self.gpa, "\"{s}\"", .{self.mount_path});
    defer self.gpa.free(mounted);
    const rewritten = try std.mem.replaceOwned(u8, self.gpa, args, quoted, mounted);
    // Anything else on disk it names is outside the tape: not replayed.
    if (std.mem.indexOf(u8, rewritten, "\"/") != null or std.mem.indexOf(u8, rewritten, "\"\\\\") != null) {
        self.gpa.free(rewritten);
        return;
    }
    try self.strings.append(self.gpa, rewritten);
    const id_owned = try self.gpa.dupe(u8, id);
    try self.strings.append(self.gpa, id_owned);

    const at = if (self.ops.items.len == 0) lead_ms else self.last_at + @max(self.last_ms, gap_ms);
    try self.ops.append(self.gpa, .{ .at = at, .ms = showing_ms, .do = .{ .command = .{ .id = id_owned, .args = rewritten } } });
    self.last_at = at;
    self.last_ms = showing_ms;
}

/// Whether anything was recorded worth a tape.
pub fn empty(self: *const Recording) bool {
    return self.ops.items.len == 0;
}

/// The tape: its slices are in `arena`, its strings the recording's.
pub fn toTape(self: *const Recording, arena: std.mem.Allocator) !Tape {
    // The name it was recorded under (`start`): an untitled document's has its format's extension.
    const base = std.fs.path.basename(self.mount_path);
    const root = std.fs.path.dirname(self.mount_path).?;
    const ops = try arena.alloc(Tape.Op, self.ops.items.len + 1);
    ops[0] = .{ .at = 0, .do = .{ .keyframe = 0 } };
    @memcpy(ops[1..], self.ops.items);
    const title = try std.fmt.allocPrint(arena, "{s} works on {s}", .{ self.label, base });
    const chapters = try arena.alloc(Tape.Chapter, self.others.items.len + 1);
    chapters[0] = .{ .at = 0, .title = title };
    const keyframes = try arena.alloc(Tape.Keyframe, self.others.items.len + 1);
    keyframes[0] = try keyframe(arena, root, base, self.bytes);
    for (self.others.items, 1..) |o, i| {
        chapters[i] = .{ .at = o.at, .title = o.title };
        keyframes[i] = try keyframe(arena, root, base, o.bytes);
    }
    return .{ .name = self.name, .title = title, .ops = ops, .chapters = chapters, .keyframes = keyframes };
}

fn keyframe(arena: std.mem.Allocator, root: []const u8, base: []const u8, bytes: []const u8) !Tape.Keyframe {
    return .{
        .root = root,
        .files = try arena.dupe(Tape.File, &.{.{ .path = base, .text = bytes }}),
        .open = try arena.dupe([]const u8, &.{base}),
        // As the person has it: a seek back then changes nothing but the document.
        .layout = .keep,
    };
}

/// The tape, written as `<dir>/<name>.tape` (the binary form). Returns its path.
pub fn write(self: *Recording, dir: []const u8, io: std.Io) ![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena_state.deinit();
    const t = try self.toTape(arena_state.allocator());
    const encoded = try tape.binary.encode(self.gpa, t, .{});
    defer self.gpa.free(encoded);
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const file_name = try std.fmt.allocPrint(self.gpa, "{s}.tape", .{self.name});
    defer self.gpa.free(file_name);
    const out = try std.fs.path.join(self.gpa, &.{ dir, file_name });
    errdefer self.gpa.free(out);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out, .data = encoded });
    return out;
}

test "a document another hand changed becomes a keyframe, credited, between the agent's steps" {
    const gpa = std.testing.allocator;
    var rec: Recording = .{
        .gpa = gpa,
        .name = try gpa.dupe(u8, "sword-1"),
        .label = try gpa.dupe(u8, "Claude"),
        .path = try gpa.dupe(u8, "/p/sword.pixi"),
        .mount_path = try gpa.dupe(u8, "demo://sword-1/sword.pixi"),
        .owner_id = try gpa.dupe(u8, "pixi"),
        .bytes = try gpa.dupe(u8, "claimed"),
        .known = try gpa.dupe(u8, "claimed"),
    };
    defer rec.deinit();

    // The agent's first step, on the document as claimed: nothing else happened.
    try rec.adopt("claimed", "The person");
    try rec.note("pixi.draw", ".{ .path = \"/p/sword.pixi\" }", 400);
    try rec.settle("claimed+draw");

    // The person edits; the agent's next step finds it.
    try rec.adopt("claimed+draw+person", "The person");
    try rec.note("pixi.draw", ".{ .path = \"/p/sword.pixi\" }", 0);
    try rec.settle("claimed+draw+person+draw");

    // Nothing changed behind the agent: no keyframe.
    try rec.adopt("claimed+draw+person+draw", "The person");

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const t = try rec.toTape(arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 2), t.keyframes.len);
    try std.testing.expectEqualStrings("claimed", t.keyframes[0].files[0].text);
    try std.testing.expectEqualStrings("claimed+draw+person", t.keyframes[1].files[0].text);
    try std.testing.expectEqual(@as(usize, 2), t.chapters.len);
    try std.testing.expectEqualStrings("The person changed sword.pixi", t.chapters[1].title);

    // Ops: keyframe 0, the agent's step, the person's keyframe, the agent's next step.
    try std.testing.expectEqual(@as(usize, 4), t.ops.len);
    try std.testing.expectEqual(@as(u32, 0), t.ops[0].do.keyframe);
    try std.testing.expect(t.ops[1].do == .command);
    try std.testing.expectEqual(@as(u32, 1), t.ops[2].do.keyframe);
    try std.testing.expectEqual(t.chapters[1].at, t.ops[2].at);
    try std.testing.expect(t.ops[3].do == .command);
    try std.testing.expect(t.ops[1].at < t.ops[2].at and t.ops[2].at < t.ops[3].at);

    // It survives the binary form a tape is written in.
    const encoded = try tape.binary.encode(gpa, t, .{});
    defer gpa.free(encoded);
    var back = try tape.binary.read(gpa, encoded, .{});
    defer back.deinit();
    try std.testing.expectEqual(@as(usize, 2), back.tape.keyframes.len);
}
