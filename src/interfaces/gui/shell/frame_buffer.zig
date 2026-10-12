//! The shell's CPU fallback framebuffer: reuse it until the drawable size
//! changes, then release it before allocating the new shape.
const std = @import("std");
const raster = @import("ra8_render").raster;
const Size = @import("../platform.zig").Size;

pub fn fit(current: *?raster.Framebuffer, allocator: std.mem.Allocator, size: Size) !*raster.Framebuffer {
    if (current.*) |*frame| {
        if (frame.width == size.width and frame.height == size.height) return frame;
        frame.deinit(allocator);
        current.* = null;
    }
    current.* = try raster.Framebuffer.init(allocator, size.width, size.height);
    return &current.*.?;
}
