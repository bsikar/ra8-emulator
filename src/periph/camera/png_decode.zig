//! PNG: 8-bit greyscale, grey+alpha, RGB, RGBA and palette pictures,
//! non-interlaced, decoded into the camera converter's RGB frame. Alpha is
//! dropped. Every chunk's CRC is checked; IDAT data is inflated with the
//! standard library's zlib and the five scanline filters are undone in place.
const std = @import("std");
const decoded = @import("decoded_image.zig");
const convert = @import("pixel_convert.zig");

const Image = decoded.Image;
const Error = decoded.DecodeError;

pub const signature = [8]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };

pub fn claims(bytes: []const u8) bool {
    return bytes.len >= signature.len and std.mem.eql(u8, bytes[0..signature.len], &signature);
}

/// The colour types this decoder takes, by their PNG code.
pub const Colour = enum(u8) { grey = 0, rgb = 2, palette = 3, grey_alpha = 4, rgba = 6 };

const Header = struct {
    width: u32,
    height: u32,
    colour: Colour,

    fn channels(self: Header) usize {
        return switch (self.colour) {
            .grey, .palette => 1,
            .grey_alpha => 2,
            .rgb => 3,
            .rgba => 4,
        };
    }

    fn rowBytes(self: Header) usize {
        return @as(usize, self.width) * self.channels();
    }
};

/// What the chunk walk gathered: the header, the palette and every IDAT
/// payload joined in order.
const Parts = struct {
    header: Header,
    palette: [256]convert.Rgb = undefined,
    palette_len: usize = 0,
    data: std.ArrayListUnmanaged(u8) = .empty,
};

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!Image {
    if (!claims(bytes)) return error.BadHeader;
    var parts = try walk(allocator, bytes);
    defer parts.data.deinit(allocator);
    const header = parts.header;
    if (header.colour == .palette and parts.palette_len == 0) return error.BadHeader;
    var image = try Image.alloc(allocator, header.width, header.height);
    errdefer image.deinit(allocator);
    const stride = header.rowBytes() + 1;
    const raw = try allocator.alloc(u8, stride * header.height);
    defer allocator.free(raw);
    try inflate(parts.data.items, raw);
    try unfilter(raw, header);
    try pixels(image, raw, &parts);
    return image;
}

fn walk(allocator: std.mem.Allocator, bytes: []const u8) Error!Parts {
    var at: usize = signature.len;
    var parts: Parts = .{ .header = try readHeader(bytes, &at) };
    errdefer parts.data.deinit(allocator);
    while (true) {
        const chunk = try nextChunk(bytes, &at);
        if (std.mem.eql(u8, chunk.kind, "IEND")) return parts;
        if (std.mem.eql(u8, chunk.kind, "IDAT")) {
            try parts.data.appendSlice(allocator, chunk.data);
        } else if (std.mem.eql(u8, chunk.kind, "PLTE")) {
            if (chunk.data.len % 3 != 0 or chunk.data.len > 768 or chunk.data.len == 0) return error.BadHeader;
            parts.palette_len = chunk.data.len / 3;
            for (parts.palette[0..parts.palette_len], 0..) |*entry, index| {
                const rgb = chunk.data[index * 3 ..][0..3];
                entry.* = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
            }
        }
    }
}

fn readHeader(bytes: []const u8, at: *usize) Error!Header {
    const chunk = try nextChunk(bytes, at);
    if (!std.mem.eql(u8, chunk.kind, "IHDR") or chunk.data.len != 13) return error.BadHeader;
    const data = chunk.data;
    const depth = data[8];
    const colour = std.enums.fromInt(Colour, data[9]) orelse return error.Unsupported;
    if (data[10] != 0 or data[11] != 0) return error.BadHeader;
    if (data[12] == 1) return error.Interlaced;
    if (data[12] != 0) return error.BadHeader;
    if (depth != 8) return error.Unsupported;
    return .{
        .width = std.mem.readInt(u32, data[0..4], .big),
        .height = std.mem.readInt(u32, data[4..8], .big),
        .colour = colour,
    };
}

const Chunk = struct { kind: []const u8, data: []const u8 };

fn nextChunk(bytes: []const u8, at: *usize) Error!Chunk {
    if (bytes.len - at.* < 12) return error.Truncated;
    const len = std.mem.readInt(u32, bytes[at.*..][0..4], .big);
    if (bytes.len - at.* - 12 < len) return error.Truncated;
    const body = bytes[at.* + 4 ..][0 .. 4 + len];
    const crc = std.mem.readInt(u32, bytes[at.* + 8 + len ..][0..4], .big);
    if (std.hash.Crc32.hash(body) != crc) return error.BadCrc;
    at.* += 12 + len;
    return .{ .kind = body[0..4], .data = body[4..] };
}

fn inflate(data: []const u8, raw: []u8) Error!void {
    var stream = std.io.fixedBufferStream(data);
    var inflater = std.compress.zlib.decompressor(stream.reader());
    const got = inflater.reader().readAll(raw) catch return error.Corrupt;
    if (got != raw.len) return error.Truncated;
}

/// Undo each row's filter in place. A row's "previous" bytes are the row
/// above after its own filter was undone, which in-place order gives us.
fn unfilter(raw: []u8, header: Header) Error!void {
    const bpp = header.channels();
    const len = header.rowBytes();
    const stride = len + 1;
    var row: usize = 0;
    while (row < header.height) : (row += 1) {
        const line = raw[row * stride + 1 ..][0..len];
        const above: ?[]const u8 = if (row == 0) null else raw[(row - 1) * stride + 1 ..][0..len];
        const kind = raw[row * stride];
        for (line, 0..) |*byte, index| {
            const a: u8 = if (index >= bpp) line[index - bpp] else 0;
            const b: u8 = if (above) |up| up[index] else 0;
            const c: u8 = if (above != null and index >= bpp) above.?[index - bpp] else 0;
            byte.* +%= switch (kind) {
                0 => 0,
                1 => a,
                2 => b,
                3 => @intCast((@as(u16, a) + b) / 2),
                4 => paeth(a, b, c),
                else => return error.Corrupt,
            };
        }
    }
}

pub fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn pixels(image: Image, raw: []const u8, parts: *const Parts) Error!void {
    const header = parts.header;
    const channels = header.channels();
    const stride = header.rowBytes() + 1;
    for (image.pixels, 0..) |*pixel, index| {
        const row = index / header.width;
        const column = index % header.width;
        const s = raw[row * stride + 1 + column * channels ..][0..channels];
        pixel.* = switch (header.colour) {
            .grey, .grey_alpha => .{ .r = s[0], .g = s[0], .b = s[0] },
            .rgb, .rgba => .{ .r = s[0], .g = s[1], .b = s[2] },
            .palette => if (s[0] < parts.palette_len) parts.palette[s[0]] else return error.BadHeader,
        };
    }
}
