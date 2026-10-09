//! Turns a source's native pixels into the bytes the firmware asked for.
//!
//! Decoding sources (still image, video, pipe, webcam) hand over one frame
//! of 8-bit RGB at whatever size they have. The firmware programmed the
//! OV5640 and CEU for a pixel format and a size; this file maps one onto
//! the other, so a source only decodes.
//!
//! RGB565 is stored little-endian, the way a Cortex-M halfword read sees
//! it. YUV422 is YUYV (Y0 U Y1 V), BT.601 studio range (Y 16..235), with U
//! and V averaged over the pair. Scaling is nearest-neighbour, which keeps
//! every output byte a pure function of the source frame.
const std = @import("std");

pub const Format = enum {
    rgb565,
    yuv422,

    /// Every supported format packs two bytes per pixel.
    pub const bytes_per_pixel: u32 = 2;
};

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

/// One native frame, row-major, `width * height` pixels of three bytes
/// each (R, G, B): the bytes a host decoder or capture hands over.
pub const Frame = struct {
    width: u32,
    height: u32,
    pixels: []const u8,

    pub fn at(self: Frame, x: u32, y: u32) Rgb {
        const p = self.pixels[(@as(usize, y) * self.width + x) * 3 ..][0..3];
        return .{ .r = p[0], .g = p[1], .b = p[2] };
    }
};

/// The source pixel a destination pixel samples, nearest-neighbour.
pub fn sample(frame: Frame, x: u32, y: u32, out_width: u32, out_lines: u32) Rgb {
    const sx: u32 = @intCast(@as(u64, x) * frame.width / out_width);
    const sy: u32 = @intCast(@as(u64, y) * frame.height / out_lines);
    return frame.at(sx, sy);
}

pub fn rgb565(c: Rgb) [2]u8 {
    const value: u16 = @as(u16, c.r >> 3) << 11 | @as(u16, c.g >> 2) << 5 | (c.b >> 3);
    return .{ @truncate(value), @truncate(value >> 8) };
}

pub fn luma(c: Rgb) u8 {
    return clamp(((66 * @as(i32, c.r) + 129 * @as(i32, c.g) + 25 * @as(i32, c.b) + 128) >> 8) + 16);
}

pub fn blueDiff(c: Rgb) i32 {
    return ((-38 * @as(i32, c.r) - 74 * @as(i32, c.g) + 112 * @as(i32, c.b) + 128) >> 8) + 128;
}

pub fn redDiff(c: Rgb) i32 {
    return ((112 * @as(i32, c.r) - 94 * @as(i32, c.g) - 18 * @as(i32, c.b) + 128) >> 8) + 128;
}

/// The four YUYV bytes for a pixel pair.
pub fn yuyv(left: Rgb, right: Rgb) [4]u8 {
    const u = clamp(@divFloor(blueDiff(left) + blueDiff(right), 2));
    const v = clamp(@divFloor(redDiff(left) + redDiff(right), 2));
    return .{ luma(left), u, luma(right), v };
}

fn clamp(value: i32) u8 {
    return @intCast(std.math.clamp(value, 0, 255));
}

/// Byte `index` of destination line `row`, for a line `width` bytes wide
/// and a frame `lines` lines tall. A trailing odd byte reads as zero.
pub fn byteAt(frame: Frame, format: Format, row: u32, index: u32, width: u32, lines: u32) u8 {
    const pixels = width / Format.bytes_per_pixel;
    switch (format) {
        .rgb565 => {
            const x = index / 2;
            if (x >= pixels) return 0;
            return rgb565(sample(frame, x, row, pixels, lines))[index % 2];
        },
        .yuv422 => {
            const left = index / 4 * 2;
            if (left >= pixels) return 0;
            const right = @min(left + 1, pixels - 1);
            const pair = yuyv(sample(frame, left, row, pixels, lines), sample(frame, right, row, pixels, lines));
            return pair[index % 4];
        },
    }
}
