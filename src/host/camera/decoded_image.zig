//! A still image a camera source decoded, owned by the caller.
//!
//! Decoders (PPM, BMP, PNG) all land on this one shape so the converter
//! never learns which file format a picture came from. Pixels are packed
//! 8-bit R, G, B bytes, row-major, which is the frame the camera
//! component reads; only standard types cross that boundary.
const std = @import("std");

/// The largest picture a decoder accepts. Bigger than any OV5640 mode
/// (2592x1944) with room to spare, and small enough that a corrupt header
/// cannot ask for gigabytes.
pub const max_pixels: u64 = 4096 * 4096;

pub const DecodeError = error{ BadHeader, Truncated, Unsupported, TooLarge, OutOfMemory, BadCrc, Interlaced, Corrupt };

/// One pixel: red, green, blue.
pub const Rgb = [3]u8;

pub const Image = struct {
    width: u32,
    height: u32,
    /// `width * height * bytes_per_pixel` bytes.
    pixels: []u8,

    pub const bytes_per_pixel = 3;

    /// Room for a `width` by `height` picture, refusing an empty or
    /// oversized one before anything is allocated.
    pub fn alloc(allocator: std.mem.Allocator, width: u32, height: u32) DecodeError!Image {
        if (width == 0 or height == 0) return error.BadHeader;
        const count = @as(u64, width) * height;
        if (count > max_pixels) return error.TooLarge;
        const pixels = try allocator.alloc(u8, @intCast(count * bytes_per_pixel));
        return .{ .width = width, .height = height, .pixels = pixels };
    }

    pub fn set(self: Image, index: usize, rgb: Rgb) void {
        self.pixels[index * bytes_per_pixel ..][0..bytes_per_pixel].* = rgb;
    }

    pub fn get(self: Image, index: usize) Rgb {
        return self.pixels[index * bytes_per_pixel ..][0..bytes_per_pixel].*;
    }

    pub fn deinit(self: Image, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};
