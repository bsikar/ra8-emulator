//! Builds small PNG files for png_decode_test.zig: the caller gives raw
//! samples and a filter per row, and gets a complete file with real CRCs and
//! a zlib stream. The forward filters follow the PNG spec, section 9.
const std = @import("std");

pub const Spec = struct {
    width: u32,
    height: u32,
    colour: u8,
    pixels: []const u8,
    filters: []const u8,
    palette: ?[]const u8 = null,
    depth: u8 = 8,
    interlace: u8 = 0,
    split_idat: bool = false,
    /// Leave the IDAT empty, for refusals that must fire before inflating.
    no_data: bool = false,
};

fn channels(colour: u8) usize {
    return switch (colour) {
        2 => 3,
        4 => 2,
        6 => 4,
        else => 1,
    };
}

pub fn build(allocator: std.mem.Allocator, spec: Spec) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, &.{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' });
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], spec.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], spec.height, .big);
    ihdr[8..13].* = .{ spec.depth, spec.colour, 0, 0, spec.interlace };
    try chunk(allocator, &out, "IHDR", &ihdr);
    if (spec.palette) |palette| try chunk(allocator, &out, "PLTE", palette);
    const data = try compressed(allocator, spec);
    defer allocator.free(data);
    if (spec.split_idat and data.len > 2) {
        try chunk(allocator, &out, "IDAT", data[0 .. data.len / 2]);
        try chunk(allocator, &out, "IDAT", data[data.len / 2 ..]);
    } else {
        try chunk(allocator, &out, "IDAT", data);
    }
    try chunk(allocator, &out, "IEND", "");
    return out.toOwnedSlice(allocator);
}

fn chunk(allocator: std.mem.Allocator, out: *std.ArrayList(u8), kind: *const [4]u8, data: []const u8) !void {
    var word: [4]u8 = undefined;
    std.mem.writeInt(u32, &word, @intCast(data.len), .big);
    try out.appendSlice(allocator, &word);
    const start = out.items.len;
    try out.appendSlice(allocator, kind);
    try out.appendSlice(allocator, data);
    std.mem.writeInt(u32, &word, std.hash.Crc32.hash(out.items[start..]), .big);
    try out.appendSlice(allocator, &word);
}

fn compressed(allocator: std.mem.Allocator, spec: Spec) ![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(allocator);
    if (!spec.no_data) try filtered(allocator, &raw, spec);
    // Compress.init needs a few bytes of output buffer up front.
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 64);
    errdefer out.deinit();
    const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(window);
    var deflater = try std.compress.flate.Compress.init(&out.writer, window, .zlib, .default);
    try deflater.writer.writeAll(raw.items);
    try deflater.finish();
    return out.toOwnedSlice();
}

fn filtered(allocator: std.mem.Allocator, raw: *std.ArrayList(u8), spec: Spec) !void {
    const bpp = channels(spec.colour);
    const len = @as(usize, spec.width) * bpp;
    for (spec.filters, 0..) |kind, row| {
        try raw.append(allocator, kind);
        const line = spec.pixels[row * len ..][0..len];
        for (line, 0..) |byte, index| {
            const a: u8 = if (index >= bpp) line[index - bpp] else 0;
            const b: u8 = if (row > 0) spec.pixels[(row - 1) * len + index] else 0;
            const c: u8 = if (row > 0 and index >= bpp) spec.pixels[(row - 1) * len + index - bpp] else 0;
            const predicted: u8 = switch (kind) {
                1 => a,
                2 => b,
                3 => @intCast((@as(u16, a) + b) / 2),
                4 => paeth(a, b, c),
                else => 0,
            };
            try raw.append(allocator, byte -% predicted);
        }
    }
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p: i16 = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    return if (pa <= pb and pa <= pc) a else if (pb <= pc) b else c;
}
