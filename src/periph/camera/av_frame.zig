//! Frames off the macOS capture delegate (RA8EMU-502). AVFoundation hands
//! the delegate a CVPixelBuffer on its own dispatch queue; the delegate
//! locks it and puts the bytes here, and the emulator's read takes the
//! newest one. 2vuy (U, Y0, V, Y1) is swizzled to YUYV and BGRA turned into
//! RGB24, so the WebcamSource that decodes V4L2 and Media Foundation frames
//! decodes these too. Rows honour the buffer's bytes-per-row padding.
const std = @import("std");
const v4l2 = @import("v4l2_abi.zig");

/// CoreVideo OSTypes the capture asks for.
pub const cv_2vuy: u32 = 0x3276_7579; // '2vuy', kCVPixelFormatType_422YpCbCr8
pub const cv_bgra: u32 = 0x4247_5241; // 'BGRA', kCVPixelFormatType_32BGRA

pub const Pixel = enum { uyvy, bgra };

pub fn pixelOf(os_type: u32) ?Pixel {
    if (os_type == cv_2vuy) return .uyvy;
    if (os_type == cv_bgra) return .bgra;
    return null;
}

/// The FourCC WebcamSource decodes for what this pixel becomes.
pub fn pixelformat(pixel: Pixel) u32 {
    return switch (pixel) {
        .uyvy => v4l2.pix_yuyv,
        .bgra => v4l2.pix_rgb24,
    };
}

fn inBytes(pixel: Pixel, width: usize) usize {
    return switch (pixel) {
        .uyvy => width * 2,
        .bgra => width * 4,
    };
}

pub fn outBytes(pixel: Pixel, width: usize) usize {
    return switch (pixel) {
        .uyvy => width * 2,
        .bgra => width * 3,
    };
}

/// Copies one locked buffer into `out` as YUYV or RGB24. False when the
/// buffer or `out` is too short or the geometry can't be a frame.
pub fn copy(pixel: Pixel, src: []const u8, stride: usize, width: usize, height: usize, out: []u8) bool {
    const in_row = inBytes(pixel, width);
    const out_row = outBytes(pixel, width);
    if (width == 0 or height == 0 or stride < in_row) return false;
    if (pixel == .uyvy and width % 2 != 0) return false;
    if (src.len < stride * (height - 1) + in_row or out.len < out_row * height) return false;
    for (0..height) |y| {
        const row = src[y * stride ..][0..in_row];
        const dst = out[y * out_row ..][0..out_row];
        switch (pixel) {
            .uyvy => swizzle(row, dst),
            .bgra => toRgb(row, dst),
        }
    }
    return true;
}

fn swizzle(row: []const u8, dst: []u8) void {
    var i: usize = 0;
    while (i < row.len) : (i += 4) {
        dst[i] = row[i + 1];
        dst[i + 1] = row[i];
        dst[i + 2] = row[i + 3];
        dst[i + 3] = row[i + 2];
    }
}

fn toRgb(row: []const u8, dst: []u8) void {
    for (0..row.len / 4) |p| {
        dst[p * 3] = row[p * 4 + 2];
        dst[p * 3 + 1] = row[p * 4 + 1];
        dst[p * 3 + 2] = row[p * 4];
    }
}

/// The newest converted frame, shared between the delegate's queue and
/// the emulator's read. A buffer whose size isn't the agreed one is dropped.
pub const Mailbox = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    pixel: Pixel,
    width: usize,
    height: usize,
    frame: []u8,
    fresh: bool = false,

    pub fn init(allocator: std.mem.Allocator, pixel: Pixel, width: usize, height: usize) error{OutOfMemory}!Mailbox {
        const frame = try allocator.alloc(u8, outBytes(pixel, width) * height);
        return .{ .allocator = allocator, .pixel = pixel, .width = width, .height = height, .frame = frame };
    }

    pub fn deinit(self: *Mailbox) void {
        self.allocator.free(self.frame);
    }

    /// From the delegate: keep this buffer as the newest frame.
    pub fn put(self: *Mailbox, src: []const u8, stride: usize, width: usize, height: usize) bool {
        if (width != self.width or height != self.height) return false;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!copy(self.pixel, src, stride, width, height, self.frame)) return false;
        self.fresh = true;
        return true;
    }

    /// From the read: the newest frame once; false until another arrives.
    pub fn take(self: *Mailbox, out: []u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.fresh or out.len < self.frame.len) return false;
        @memcpy(out[0..self.frame.len], self.frame);
        self.fresh = false;
        return true;
    }
};
