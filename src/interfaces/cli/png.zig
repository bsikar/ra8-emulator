//! A PNG writer for the board view (RA8EMU-73): 8-bit RGBA, one IDAT,
//! filter type 0 on every row, deflated by the standard library. Pure Zig,
//! so a frame can leave the emulator without pulling in a C image library.
const std = @import("std");

/// The eight bytes every PNG opens with.
pub const signature = [8]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };

/// Colour type 6: truecolour with alpha, 8 bits per channel.
pub const colour_rgba: u8 = 6;
pub const bytes_per_pixel: usize = 4;

pub const Error = error{ BadShape, EmptyImage };

/// Write one chunk: big-endian length, type, data, then the CRC-32 over
/// the type and data.
pub fn chunk(writer: anytype, kind: *const [4]u8, data: []const u8) !void {
    try writer.writeInt(u32, @intCast(data.len), .big);
    try writer.writeAll(kind);
    try writer.writeAll(data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    try writer.writeInt(u32, crc.final(), .big);
}

/// The 13-byte IHDR body for a width x height RGBA image.
pub fn header(width: u32, height: u32) [13]u8 {
    var body: [13]u8 = undefined;
    std.mem.writeInt(u32, body[0..4], width, .big);
    std.mem.writeInt(u32, body[4..8], height, .big);
    body[8] = 8; // bit depth
    body[9] = colour_rgba;
    body[10] = 0; // deflate
    body[11] = 0; // adaptive filtering, type 0 used throughout
    body[12] = 0; // no interlace
    return body;
}

/// Encode `rgba` (row-major, width*height*4 bytes, no padding) as a PNG.
pub fn encode(allocator: std.mem.Allocator, writer: anytype, width: u32, height: u32, rgba: []const u8) !void {
    if (width == 0 or height == 0) return Error.EmptyImage;
    const row = @as(usize, width) * bytes_per_pixel;
    if (rgba.len != row * height) return Error.BadShape;
    var idat = std.ArrayList(u8).init(allocator);
    defer idat.deinit();
    var deflater = try std.compress.zlib.compressor(idat.writer(), .{});
    for (0..height) |y| {
        try deflater.writer().writeByte(0);
        try deflater.writer().writeAll(rgba[y * row ..][0..row]);
    }
    try deflater.finish();
    try writer.writeAll(&signature);
    try chunk(writer, "IHDR", &header(width, height));
    try chunk(writer, "IDAT", idat.items);
    try chunk(writer, "IEND", "");
}

/// Unpack ARGB8888 words, the GLCDC's composited format, into RGBA bytes.
/// `out` must hold four bytes per pixel.
pub fn fromArgb(pixels: []const u32, out: []u8) Error!void {
    if (out.len != pixels.len * bytes_per_pixel) return Error.BadShape;
    for (pixels, 0..) |argb, index| {
        const at = out[index * bytes_per_pixel ..][0..bytes_per_pixel];
        at[0] = @truncate(argb >> 16);
        at[1] = @truncate(argb >> 8);
        at[2] = @truncate(argb);
        at[3] = @truncate(argb >> 24);
    }
}
