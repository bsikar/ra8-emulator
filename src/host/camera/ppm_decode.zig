//! PPM (Netpbm portable pixmap): P6 binary and P3 text, one sample per
//! byte (maxval up to 255). Samples are rescaled to 0..255 when maxval is
//! smaller. Header fields are separated by whitespace and `#` comments run
//! to the end of the line, as the Netpbm spec says.
const std = @import("std");
const decoded = @import("decoded_image.zig");

const Image = decoded.Image;

pub fn claims(bytes: []const u8) bool {
    return bytes.len >= 2 and bytes[0] == 'P' and (bytes[1] == '6' or bytes[1] == '3');
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) decoded.DecodeError!Image {
    if (!claims(bytes)) return error.BadHeader;
    var cursor = Cursor{ .bytes = bytes, .at = 2 };
    const width = try cursor.number();
    const height = try cursor.number();
    const maxval = try cursor.number();
    if (maxval == 0) return error.BadHeader;
    if (maxval > 255) return error.Unsupported;
    var image = try Image.alloc(allocator, width, height);
    errdefer image.deinit(allocator);
    if (bytes[1] == '6') {
        // Exactly one whitespace byte separates maxval from the raster.
        cursor.at += 1;
        const raster = @as(usize, width) * height * 3;
        if (cursor.at > bytes.len or bytes.len - cursor.at < raster) return error.Truncated;
        const samples = bytes[cursor.at..][0..raster];
        // The raster is R, G, B per pixel, the image's own byte order.
        for (image.pixels, samples) |*byte, sample| byte.* = scale(sample, maxval);
    } else {
        for (image.pixels) |*byte| byte.* = try cursor.sample(maxval);
    }
    return image;
}

fn scale(sample: u32, maxval: u32) u8 {
    const clamped = @min(sample, maxval);
    return @intCast((clamped * 255 + maxval / 2) / maxval);
}

const Cursor = struct {
    bytes: []const u8,
    at: usize,

    fn skip(self: *Cursor) void {
        while (self.at < self.bytes.len) {
            const byte = self.bytes[self.at];
            if (byte == '#') {
                while (self.at < self.bytes.len and self.bytes[self.at] != '\n') self.at += 1;
            } else if (std.ascii.isWhitespace(byte)) {
                self.at += 1;
            } else return;
        }
    }

    fn number(self: *Cursor) decoded.DecodeError!u32 {
        self.skip();
        const start = self.at;
        while (self.at < self.bytes.len and std.ascii.isDigit(self.bytes[self.at])) self.at += 1;
        if (self.at == start) return if (self.at >= self.bytes.len) error.Truncated else error.BadHeader;
        return std.fmt.parseInt(u32, self.bytes[start..self.at], 10) catch error.BadHeader;
    }

    fn sample(self: *Cursor, maxval: u32) decoded.DecodeError!u8 {
        return scale(try self.number(), maxval);
    }
};
