//! A compiler's diagnostics as data: `file:line:column: error: message` lines, as zig prints
//! them, read into their parts (`Build.zig`). std-only, so it tests without fizzy.
const std = @import("std");

pub const Diagnostic = struct { file: []const u8, line: u32, column: u32, kind: []const u8, message: []const u8 };

pub fn parse(line: []const u8) ?Diagnostic {
    for ([_][]const u8{ ": error: ", ": note: ", ": warning: " }) |sep| {
        const at = std.mem.indexOf(u8, line, sep) orelse continue;
        const loc = line[0..at];
        // `file:line:column`, the file possibly containing colons of its own (Windows drives).
        const c2 = std.mem.lastIndexOfScalar(u8, loc, ':') orelse return null;
        const c1 = std.mem.lastIndexOfScalar(u8, loc[0..c2], ':') orelse return null;
        return .{
            .file = loc[0..c1],
            .line = std.fmt.parseInt(u32, loc[c1 + 1 .. c2], 10) catch return null,
            .column = std.fmt.parseInt(u32, loc[c2 + 1 ..], 10) catch return null,
            .kind = sep[2 .. sep.len - 2],
            .message = line[at + sep.len ..],
        };
    }
    return null;
}

test "a compiler line reads as file, line, column, kind and message" {
    const d = parse("src/Chat.zig:521:101: error: no field named 'corner_radius' in struct 'Options'").?;
    try std.testing.expectEqualStrings("src/Chat.zig", d.file);
    try std.testing.expectEqual(@as(u32, 521), d.line);
    try std.testing.expectEqual(@as(u32, 101), d.column);
    try std.testing.expectEqualStrings("error", d.kind);
    try std.testing.expectEqualStrings("no field named 'corner_radius' in struct 'Options'", d.message);
    try std.testing.expect(parse("info: fizzy: installed plugin") == null);
    try std.testing.expectEqualStrings("note", parse("C:\\x\\a.zig:3:4: note: here").?.kind);
}
