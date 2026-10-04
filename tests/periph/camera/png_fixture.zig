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
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try out.appendSlice(&.{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' });
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], spec.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], spec.height, .big);
    ihdr[8..13].* = .{ spec.depth, spec.colour, 0, 0, spec.interlace };
    try chunk(&out, "IHDR", &ihdr);
    if (spec.palette) |palette| try chunk(&out, "PLTE", palette);
    const data = try compressed(allocator, spec);
    defer allocator.free(data);
    if (spec.split_idat and data.len > 2) {
        try chunk(&out, "IDAT", data[0 .. data.len / 2]);
        try chunk(&out, "IDAT", data[data.len / 2 ..]);
    } else {
        try chunk(&out, "IDAT", data);
    }
    try chunk(&out, "IEND", "");
    return out.toOwnedSlice();
}

fn chunk(out: *std.ArrayList(u8), kind: *const [4]u8, data: []const u8) !void {
    try out.writer().writeInt(u32, @intCast(data.len), .big);
    const start = out.items.len;
    try out.appendSlice(kind);
    try out.appendSlice(data);
    try out.writer().writeInt(u32, std.hash.Crc32.hash(out.items[start..]), .big);
}

fn compressed(allocator: std.mem.Allocator, spec: Spec) ![]u8 {
    var raw = std.ArrayList(u8).init(allocator);
    defer raw.deinit();
    if (!spec.no_data) try filtered(&raw, spec);
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    var stream = std.io.fixedBufferStream(raw.items);
    try std.compress.zlib.compress(stream.reader(), out.writer(), .{});
    return out.toOwnedSlice();
}

fn filtered(raw: *std.ArrayList(u8), spec: Spec) !void {
    const bpp = channels(spec.colour);
    const len = @as(usize, spec.width) * bpp;
    for (spec.filters, 0..) |kind, row| {
        try raw.append(kind);
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
            try raw.append(byte -% predicted);
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
