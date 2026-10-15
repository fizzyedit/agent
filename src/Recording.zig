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
ops: std.ArrayListUnmanaged(Tape.Op) = .empty,
/// Strings the ops hold.
strings: std.ArrayListUnmanaged([]u8) = .empty,
last_at: u32 = 0,
/// How long the last step goes on showing its work (`Command.Call.showing_ms`): the next starts
/// as it ends, so a replay flows from one to the next.
last_ms: u32 = 0,

/// Between a step and the next when the first shows nothing over time: a moment to see it.
const gap_ms = 150;
/// From the keyframe to the first command: time to see where it starts.
const lead_ms = 800;

pub fn start(gpa: std.mem.Allocator, doc: sdk.DocHandle, path: []const u8, label: []const u8, unix_s: i64) !Recording {
    const bytes = (try doc.owner.documentBytes(doc, path, gpa)) orelse return error.NotRecordable;
    errdefer gpa.free(bytes);
    const base = std.fs.path.basename(path);
    const stem = base[0 .. base.len - std.fs.path.extension(base).len];
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
    };
}

pub fn deinit(self: *Recording) void {
    for (self.strings.items) |s| self.gpa.free(s);
    self.strings.deinit(self.gpa);
    self.ops.deinit(self.gpa);
    inline for (.{ "name", "label", "path", "mount_path", "owner_id", "bytes" }) |f| self.gpa.free(@field(self, f));
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

/// The tape, written as `<dir>/<name>.tape` (the binary form). Returns its path.
pub fn write(self: *Recording, dir: []const u8, io: std.Io) ![]u8 {
    const base = std.fs.path.basename(self.path);
    var ops: std.ArrayListUnmanaged(Tape.Op) = .empty;
    defer ops.deinit(self.gpa);
    try ops.append(self.gpa, .{ .at = 0, .do = .{ .keyframe = 0 } });
    try ops.appendSlice(self.gpa, self.ops.items);
    const title = try std.fmt.allocPrint(self.gpa, "{s} works on {s}", .{ self.label, base });
    defer self.gpa.free(title);
    const t: Tape = .{
        .name = self.name,
        .title = title,
        .ops = ops.items,
        .chapters = &.{.{ .at = 0, .title = title }},
        .keyframes = &.{.{
            .root = std.fs.path.dirname(self.mount_path).?,
            .files = &.{.{ .path = base, .text = self.bytes }},
            .open = &.{base},
            // As the person has it: a seek back then changes nothing but the document.
            .layout = .keep,
        }},
    };
    const encoded = try tape.binary.encode(self.gpa, t);
    defer self.gpa.free(encoded);
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const file_name = try std.fmt.allocPrint(self.gpa, "{s}.tape", .{self.name});
    defer self.gpa.free(file_name);
    const out = try std.fs.path.join(self.gpa, &.{ dir, file_name });
    errdefer self.gpa.free(out);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out, .data = encoded });
    return out;
}
