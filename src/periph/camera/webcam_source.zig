//! The host webcam as the camera (RA8EMU-506): each armed capture reads
//! one frame from the negotiated V4L2 node, decodes YUYV or RGB565 to RGB
//! and hands it to the shared converter, so the firmware gets the format
//! and size it programmed.
//!
//! Frames arrive through a capture seam: the V4L2 fd at run time, a fake
//! in host tests. Rows are read at the driver's bytesperline, which may be
//! padded past width * 2. A failed read keeps the last frame, says so once
//! and never stops the run; before the first frame the capture is black.
const std = @import("std");
const frame_source = @import("frame_source.zig");
const converted = @import("converted_source.zig");
const decoded = @import("decoded_image.zig");
const still = @import("image_source.zig");
const raw = @import("pipe_frame.zig");
const abi = @import("v4l2_abi.zig");
const negotiate = @import("v4l2_negotiate.zig");

/// One frame's bytes from the device: true when `out` was filled.
pub const Capture = struct {
    ctx: *anyopaque,
    readFn: *const fn (ctx: *anyopaque, out: []u8) bool,
    closeFn: *const fn (ctx: *anyopaque) void,
};

pub const OpenError = error{ UnsupportedFormat, BadGeometry, OutOfMemory } || decoded.DecodeError;

/// The pipe decoder's name for a negotiated FourCC.
pub fn rawFormat(pixelformat: u32) ?raw.Format {
    if (pixelformat == abi.pix_yuyv) return .yuyv;
    if (pixelformat == abi.pix_rgb565) return .rgb565;
    if (pixelformat == abi.pix_rgb24) return .rgb24;
    return null;
}

pub const WebcamSource = struct {
    allocator: std.mem.Allocator,
    capture: Capture,
    agreed: negotiate.Agreed,
    format: raw.Format,
    device_path: []const u8,
    bytes: []u8,
    image: decoded.Image,
    converted: converted.Converted,
    format_control: *const u8,
    frames: u64 = 0,
    failed: bool = false,

    pub fn open(allocator: std.mem.Allocator, capture: Capture, agreed: negotiate.Agreed, device_path: []const u8, format_control: *const u8) OpenError!*WebcamSource {
        const format = rawFormat(agreed.pixelformat) orelse return error.UnsupportedFormat;
        const row = @as(usize, agreed.width) * format.bytesPerPixel();
        if (agreed.bytesperline < row or agreed.width % 2 != 0) return error.BadGeometry;
        const image = try decoded.Image.alloc(allocator, agreed.width, agreed.height);
        errdefer image.deinit(allocator);
        const bytes = try allocator.alloc(u8, @as(usize, agreed.bytesperline) * agreed.height);
        errdefer allocator.free(bytes);
        const self = try allocator.create(WebcamSource);
        self.* = .{
            .allocator = allocator,
            .capture = capture,
            .agreed = agreed,
            .format = format,
            .device_path = device_path,
            .bytes = bytes,
            .image = image,
            .converted = .{ .input = image.frame(), .format = still.formatFor(format_control.*) },
            .format_control = format_control,
        };
        @memset(image.pixels, .{ .r = 0, .g = 0, .b = 0 });
        return self;
    }

    pub fn source(self: *WebcamSource) frame_source.FrameSource {
        return .{ .context = self, .vtable = &vtable, .label = "webcam", .detail = self.device_path };
    }

    /// Read and decode one frame, keeping the last one on a failed read.
    pub fn pull(self: *WebcamSource) void {
        if (!self.capture.readFn(self.capture.ctx, self.bytes)) {
            if (!self.failed) std.debug.print("camera: webcam read failed on {s}; holding the last frame\n", .{self.device_path});
            self.failed = true;
            return;
        }
        const width = self.agreed.width;
        const stride = self.agreed.bytesperline;
        const used = @as(usize, width) * self.format.bytesPerPixel();
        for (0..self.agreed.height) |y| {
            const line = self.bytes[y * stride ..][0..used];
            raw.toRgb(self.format, line, self.image.pixels[y * width ..][0..width]);
        }
        self.frames += 1;
    }

    const vtable = frame_source.FrameSource.VTable{ .frame = frame, .fill = fill, .close = close };

    fn frame(context: *anyopaque, when: u64, shape: frame_source.Shape) void {
        const self: *WebcamSource = @ptrCast(@alignCast(context));
        self.pull();
        self.converted.format = still.formatFor(self.format_control.*);
        self.converted.source().frame(when, shape);
    }

    fn fill(context: *anyopaque, row: u32, column: u32, out: []u8) void {
        const self: *WebcamSource = @ptrCast(@alignCast(context));
        self.converted.source().fill(row, column, out);
    }

    fn close(context: *anyopaque) void {
        const self: *WebcamSource = @ptrCast(@alignCast(context));
        const allocator = self.allocator;
        self.capture.closeFn(self.capture.ctx);
        allocator.free(self.bytes);
        self.image.deinit(allocator);
        allocator.destroy(self);
    }
};
