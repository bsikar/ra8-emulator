//! A still image a camera source decoded, owned by the caller.
//!
//! Decoders (PPM, BMP, PNG) all land on this one shape so the converter
//! never learns which file format a picture came from.
const std = @import("std");
const convert = @import("pixel_convert.zig");

/// The largest picture a decoder accepts. Bigger than any OV5640 mode
/// (2592x1944) with room to spare, and small enough that a corrupt header
/// cannot ask for gigabytes.
pub const max_pixels: u64 = 4096 * 4096;

pub const DecodeError = error{ BadHeader, Truncated, Unsupported, TooLarge, OutOfMemory };

pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []convert.Rgb,

    /// Room for a `width` by `height` picture, refusing an empty or
    /// oversized one before anything is allocated.
    pub fn alloc(allocator: std.mem.Allocator, width: u32, height: u32) DecodeError!Image {
        if (width == 0 or height == 0) return error.BadHeader;
        const count = @as(u64, width) * height;
        if (count > max_pixels) return error.TooLarge;
        const pixels = try allocator.alloc(convert.Rgb, @intCast(count));
        return .{ .width = width, .height = height, .pixels = pixels };
    }

    pub fn frame(self: Image) convert.Frame {
        return .{ .width = self.width, .height = self.height, .pixels = self.pixels };
    }

    pub fn deinit(self: Image, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};
