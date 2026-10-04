//! A still picture as the camera (RA8EMU-529): `--camera-source image:PATH`.
//!
//! The file is read and decoded once, when the run starts, so a missing or
//! unreadable picture stops the run before the firmware boots. The decoder
//! is chosen by the file's magic bytes, never its name. Every capture then
//! repeats the same picture, converted to the pixel format the firmware last
//! wrote into the OV5640's FORMAT CONTROL register and scaled to the size it
//! programmed into the CEU.
const std = @import("std");
const frame_source = @import("frame_source.zig");
const convert = @import("pixel_convert.zig");
const converted = @import("converted_source.zig");
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

/// OV5640 FORMAT CONTROL (0x4300): bits 7:4 pick the output format. 0x6 is
/// RGB565. 0x3 is YUV422, which the camera example writes (0x30), and the
/// model reads every other value as YUV422 too, the only other format the
/// converter produces.
pub fn formatFor(control: u8) convert.Format {
    return if (control >> 4 == 0x6) .rgb565 else .yuv422;
}

pub const ImageSource = struct {
    allocator: std.mem.Allocator,
    image: decoded.Image,
    converted: converted.Converted,
    /// The sensor's FORMAT CONTROL byte, read again at every capture.
    format_control: *const u8,

    pub fn load(allocator: std.mem.Allocator, path: []const u8, format_control: *const u8) !*ImageSource {
        const bytes = try std.fs.cwd().readFileAlloc(allocator, path, max_file_bytes);
        defer allocator.free(bytes);
        const image = try decodeAny(allocator, bytes);
        errdefer image.deinit(allocator);
        const self = try allocator.create(ImageSource);
        self.* = .{
            .allocator = allocator,
            .image = image,
            .converted = .{ .input = image.frame(), .format = formatFor(format_control.*) },
            .format_control = format_control,
        };
        return self;
    }

    pub fn source(self: *ImageSource) frame_source.FrameSource {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable = frame_source.FrameSource.VTable{ .frame = frame, .fill = fill, .close = close };

    fn frame(context: *anyopaque, when: u64, shape: frame_source.Shape) void {
        const self: *ImageSource = @ptrCast(@alignCast(context));
        self.converted.format = formatFor(self.format_control.*);
        self.converted.source().frame(when, shape);
    }

    fn fill(context: *anyopaque, row: u32, column: u32, out: []u8) void {
        const self: *ImageSource = @ptrCast(@alignCast(context));
        self.converted.source().fill(row, column, out);
    }

    fn close(context: *anyopaque) void {
        const self: *ImageSource = @ptrCast(@alignCast(context));
        const allocator = self.allocator;
        self.image.deinit(allocator);
        allocator.destroy(self);
    }
};
