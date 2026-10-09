//! A still picture on disk for `--camera-source image:PATH` (RA8EMU-529),
//! read here in ra8_host so the camera model never opens a file
//! (RA8EMU-1011).
//!
//! The file is read and decoded once, when the run starts, so a missing or
//! unreadable picture stops the run before the firmware boots. The decoder
//! is chosen by the file's magic bytes, never its name. Every capture then
//! shows the same picture.
const std = @import("std");
const decoded = @import("decoded_image.zig");
const ppm = @import("ppm_decode.zig");
const bmp = @import("bmp_decode.zig");
const png = @import("png_decode.zig");

/// No picture worth capturing comes near this; a bigger file is refused
/// rather than read into memory.
pub const max_file_bytes: usize = 64 << 20;

/// Decode a PNG, BMP or PPM by its magic bytes.
pub fn decodeAny(allocator: std.mem.Allocator, bytes: []const u8) decoded.DecodeError!decoded.Image {
    if (png.claims(bytes)) return png.decode(allocator, bytes);
    if (bmp.claims(bytes)) return bmp.decode(allocator, bytes);
    if (ppm.claims(bytes)) return ppm.decode(allocator, bytes);
    return error.Unsupported;
}

pub const Still = struct {
    allocator: std.mem.Allocator,
    image: decoded.Image,

    pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !*Still {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_file_bytes));
        defer allocator.free(bytes);
        const image = try decodeAny(allocator, bytes);
        errdefer image.deinit(allocator);
        const self = try allocator.create(Still);
        self.* = .{ .allocator = allocator, .image = image };
        return self;
    }

    /// The picture a capture shows at any emulated time: always this one.
    pub fn picture(self: *const Still, _: u64) decoded.Image {
        return self.image;
    }

    pub fn close(self: *Still) void {
        const allocator = self.allocator;
        self.image.deinit(allocator);
        allocator.destroy(self);
    }
};
