//! A picture of fizzy, made in the bridge's own process from the raw pixels fizzy hands over: its
//! frame pays for one read back and one copy, and everything an image file costs (a crop, straight
//! alpha, scaling down to what a model looks at, the PNG encode) is paid here, never on fizzy's UI
//! thread.
//!
//! The raw file fizzy's agent plugin writes (`ui.capture`): `"FZPX"`, the width and the height as
//! little-endian `u32`s, then the pixels, premultiplied RGBA, row by row.
const std = @import("std");

pub const magic = "FZPX";
pub const header_len = 12;

/// Premultiplied RGBA, row by row.
pub const Raw = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
};

/// A part of a picture, in its pixels.
pub const Rect = struct { x: i64, y: i64, w: i64, h: i64 };

/// What a model is shown at most: images larger than this are scaled down before it sees them
/// anyway (about 1.15 megapixels, and 1568 pixels on the long side), so sending more is only
/// cost.
pub const model_long_side = 1568;
pub const model_pixels = 1_150_000;

/// The raw picture in `bytes` (`ui.capture`'s file), borrowed from them.
pub fn parse(bytes: []const u8) !Raw {
    if (bytes.len < header_len or !std.mem.eql(u8, bytes[0..4], magic)) return error.NotARawPicture;
    const w = std.mem.readInt(u32, bytes[4..8], .little);
    const h = std.mem.readInt(u32, bytes[8..12], .little);
    const n = @as(usize, w) * h * 4;
    if (bytes.len - header_len < n) return error.TruncatedPicture;
    return .{ .pixels = bytes[header_len..][0..n], .width = w, .height = h };
}

/// The size `w` by `h` scales to so that it is no larger than a model is shown, nor than
/// `long_side` on its long side (0: the model's own). Never larger than it was.
pub fn fitted(w: u32, h: u32, long_side: u32) struct { w: u32, h: u32 } {
    if (w == 0 or h == 0) return .{ .w = w, .h = h };
    const side: f64 = @floatFromInt(if (long_side == 0) model_long_side else @min(long_side, model_long_side));
    const fw: f64 = @floatFromInt(w);
    const fh: f64 = @floatFromInt(h);
    var s = @min(1.0, side / @max(fw, fh));
    s = @min(s, @sqrt(@as(f64, model_pixels) / (fw * fh)));
    return .{ .w = @max(1, @as(u32, @intFromFloat(@floor(fw * s)))), .h = @max(1, @as(u32, @intFromFloat(@floor(fh * s)))) };
}

/// `raw`'s part `crop` (the whole of it for null; clamped to it), scaled to `out_w` by `out_h` by
/// averaging the pixels each output pixel covers, in straight-alpha RGBA. Averaged premultiplied
/// and divided after, so a pixel half over transparency is not darkened.
pub fn scaled(gpa: std.mem.Allocator, raw: Raw, crop: ?Rect, out_w: u32, out_h: u32) ![]u8 {
    const r = clamp(crop orelse Rect{ .x = 0, .y = 0, .w = raw.width, .h = raw.height }, raw.width, raw.height);
    const out = try gpa.alloc(u8, @as(usize, out_w) * out_h * 4);
    if (r.w == 0 or r.h == 0) {
        @memset(out, 0);
        return out;
    }
    const sw: u64 = @intCast(r.w);
    const sh: u64 = @intCast(r.h);
    for (0..out_h) |oy| {
        const y0 = r.y + @as(i64, @intCast(oy * sh / out_h));
        const y1 = @max(y0 + 1, r.y + @as(i64, @intCast((oy + 1) * sh / out_h)));
        for (0..out_w) |ox| {
            const x0 = r.x + @as(i64, @intCast(ox * sw / out_w));
            const x1 = @max(x0 + 1, r.x + @as(i64, @intCast((ox + 1) * sw / out_w)));
            var sum: [4]u64 = .{ 0, 0, 0, 0 };
            var y = y0;
            while (y < y1) : (y += 1) {
                const row = raw.pixels[@as(usize, @intCast(y)) * raw.width * 4 ..];
                var x = x0;
                while (x < x1) : (x += 1) {
                    const p = row[@as(usize, @intCast(x)) * 4 ..][0..4];
                    inline for (0..4) |c| sum[c] += p[c];
                }
            }
            const count: u64 = @intCast((y1 - y0) * (x1 - x0));
            const o = out[(oy * out_w + ox) * 4 ..][0..4];
            const a = sum[3];
            o[3] = @intCast((a + count / 2) / count);
            inline for (0..3) |c| o[c] = if (a == 0) 0 else @intCast(@min(255, (sum[c] * 255 + a / 2) / a));
        }
    }
    return out;
}

fn clamp(r: Rect, w: u32, h: u32) Rect {
    const x0 = std.math.clamp(r.x, 0, w);
    const y0 = std.math.clamp(r.y, 0, h);
    const x1 = std.math.clamp(r.x + r.w, x0, w);
    const y1 = std.math.clamp(r.y + r.h, y0, h);
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

/// `rgba` (straight alpha, `w` by `h`) as a PNG, compressed fast rather than small: it crosses
/// a local pipe once, and a model's cost is its size in pixels, not bytes.
pub fn png(gpa: std.mem.Allocator, rgba: []const u8, w: u32, h: u32) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const ow = &out.writer;
    try ow.writeAll("\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 }; // 8 bits, RGBA, deflate, no adaptive filter choice, no interlace
    try chunk(ow, "IHDR", &ihdr);

    // The image data: each row behind its filter byte (0, none), deflated as one zlib stream.
    var idat: std.Io.Writer.Allocating = .init(gpa);
    defer idat.deinit();
    try idat.ensureUnusedCapacity(64 * 1024);
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    const z = try gpa.create(std.compress.flate.Compress);
    defer gpa.destroy(z);
    z.* = try .init(&idat.writer, window, .zlib, .fastest);
    const row = @as(usize, w) * 4;
    for (0..h) |y| {
        try z.writer.writeByte(0);
        try z.writer.writeAll(rgba[y * row ..][0..row]);
    }
    try z.finish();
    try chunk(ow, "IDAT", idat.written());
    try chunk(ow, "IEND", "");
    return out.toOwnedSlice();
}

fn chunk(w: *std.Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    try w.writeInt(u32, @intCast(data.len), .big);
    try w.writeAll(kind);
    try w.writeAll(data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    try w.writeInt(u32, crc.final(), .big);
}

test "a picture fits what a model is shown, never growing" {
    try std.testing.expectEqual(@as(u32, 1200), fitted(1200, 800, 0).w);
    const retina = fitted(2400, 1600, 0);
    try std.testing.expect(retina.w <= model_long_side and @as(u64, retina.w) * retina.h <= model_pixels);
    try std.testing.expectEqual(@as(u32, 300), fitted(600, 400, 300).w);
}

test "scaling averages premultiplied pixels into straight alpha" {
    // 2 by 1: opaque red, then fully transparent. Halved to 1 by 1: red at half alpha, not dark red.
    const raw: Raw = .{ .pixels = &.{ 255, 0, 0, 255, 0, 0, 0, 0 }, .width = 2, .height = 1 };
    const out = try scaled(std.testing.allocator, raw, null, 1, 1);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 128 }, out);
}

test "a crop is clamped to the picture" {
    const raw: Raw = .{ .pixels = &.{ 1, 1, 1, 255, 2, 2, 2, 255, 3, 3, 3, 255, 4, 4, 4, 255 }, .width = 2, .height = 2 };
    const out = try scaled(std.testing.allocator, raw, .{ .x = 1, .y = 1, .w = 10, .h = 10 }, 1, 1);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualSlices(u8, &.{ 4, 4, 4, 255 }, out);
}

test "the PNG decodes back to its pixels" {
    const gpa = std.testing.allocator;
    const rgba = [_]u8{ 10, 20, 30, 255, 40, 50, 60, 128, 70, 80, 90, 0, 1, 2, 3, 4 };
    const file = try png(gpa, &rgba, 2, 2);
    defer gpa.free(file);
    try std.testing.expectEqualSlices(u8, "\x89PNG", file[0..4]);
    // The IDAT chunk sits after the signature (8) and IHDR (4 + 4 + 13 + 4).
    const at = 8 + 25;
    const len = std.mem.readInt(u32, file[at..][0..4], .big);
    try std.testing.expectEqualSlices(u8, "IDAT", file[at + 4 ..][0..4]);
    var in: std.Io.Reader = .fixed(file[at + 8 ..][0..len]);
    var buf: [std.compress.flate.max_window_len]u8 = undefined;
    var d: std.compress.flate.Decompress = .init(&in, .zlib, &buf);
    var got: [18]u8 = undefined;
    try d.reader.readSliceAll(&got);
    try std.testing.expectEqualSlices(u8, &.{ 0, 10, 20, 30, 255, 40, 50, 60, 128, 0, 70, 80, 90, 0, 1, 2, 3, 4 }, &got);
}
