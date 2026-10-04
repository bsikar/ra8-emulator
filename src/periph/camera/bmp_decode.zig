//! BMP (Windows bitmap): uncompressed (BI_RGB) 24- and 32-bit pictures,
//! bottom-up (positive height) or top-down (negative height). Rows are
//! padded to four bytes and pixels are stored blue, green, red, then an
//! ignored fourth byte at 32 bits. Paletted and compressed files are
//! refused as unsupported rather than guessed at.
const std = @import("std");
const decoded = @import("decoded_image.zig");

const Image = decoded.Image;

/// Offsets into the file header and the BITMAPINFOHEADER after it.
const at = struct {
    const pixel_offset = 10;
    const width = 18;
    const height = 22;
    const bits = 28;
    const compression = 30;
    const header_end = 34;
};

pub fn claims(bytes: []const u8) bool {
    return bytes.len >= 2 and bytes[0] == 'B' and bytes[1] == 'M';
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) decoded.DecodeError!Image {
    if (!claims(bytes)) return error.BadHeader;
    if (bytes.len < at.header_end) return error.Truncated;
    const bits = std.mem.readInt(u16, bytes[at.bits..][0..2], .little);
    const compression = std.mem.readInt(u32, bytes[at.compression..][0..4], .little);
    if (compression != 0 or (bits != 24 and bits != 32)) return error.Unsupported;
    const width = std.mem.readInt(i32, bytes[at.width..][0..4], .little);
    const height = std.mem.readInt(i32, bytes[at.height..][0..4], .little);
    if (width <= 0 or height == 0 or height == std.math.minInt(i32)) return error.BadHeader;
    const rows: u32 = @intCast(@abs(height));
    var image = try Image.alloc(allocator, @intCast(width), rows);
    errdefer image.deinit(allocator);
    const step: usize = bits / 8;
    const stride = (@as(usize, image.width) * step + 3) / 4 * 4;
    const offset = std.mem.readInt(u32, bytes[at.pixel_offset..][0..4], .little);
    if (offset > bytes.len or bytes.len - offset < stride * rows) return error.Truncated;
    const raster = bytes[offset..];
    for (0..rows) |row| {
        // Bottom-up files store the last row first.
        const stored = if (height > 0) rows - 1 - row else row;
        const line = raster[stored * stride ..][0 .. image.width * step];
        for (image.pixels[row * image.width ..][0..image.width], 0..) |*pixel, column| {
            const p = line[column * step ..];
            pixel.* = .{ .r = p[2], .g = p[1], .b = p[0] };
        }
    }
    return image;
}
