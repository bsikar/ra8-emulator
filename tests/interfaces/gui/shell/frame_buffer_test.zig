//! The shell's fallback frame keeps its pixels until the drawable size changes.
const std = @import("std");
const raster = @import("ra8").render.raster;
const Color = @import("ra8").render.draw_list.Color;
const cache = @import("gui_app").shell.loop.frame_buffer;

test "the same drawable size keeps the existing framebuffer and its pixels" {
    var current: ?raster.Framebuffer = null;
    defer if (current) |*frame| frame.deinit(std.testing.allocator);
    const first = try cache.fit(&current, std.testing.allocator, .{ .width = 8, .height = 4 });
    const pixels = first.pixels.ptr;
    const ink = Color.rgb(12, 34, 56);
    first.put(2, 1, ink);
    const next = try cache.fit(&current, std.testing.allocator, .{ .width = 8, .height = 4 });
    try std.testing.expectEqual(pixels, next.pixels.ptr);
    try std.testing.expectEqual(ink, next.at(2, 1));
}

test "a changed drawable size replaces the frame with a cleared new shape" {
    var current: ?raster.Framebuffer = null;
    defer if (current) |*frame| frame.deinit(std.testing.allocator);
    const first = try cache.fit(&current, std.testing.allocator, .{ .width = 8, .height = 4 });
    first.put(0, 0, Color.rgb(12, 34, 56));
    const resized = try cache.fit(&current, std.testing.allocator, .{ .width = 3, .height = 5 });
    try std.testing.expectEqual(@as(u32, 3), resized.width);
    try std.testing.expectEqual(@as(u32, 5), resized.height);
    try std.testing.expectEqual(@as(usize, 15), resized.pixels.len);
    const clear = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
    for (resized.pixels) |pixel| try std.testing.expectEqual(clear, pixel);
}
