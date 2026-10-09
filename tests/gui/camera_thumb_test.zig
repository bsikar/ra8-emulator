//! Covers src/gui/camera_thumb.zig: the chosen picture's preview, its size,
//! its averaged pixels, reading it from the file, and where it is drawn.
const std = @import("std");
const ra8 = @import("ra8");
const thumb = ra8.gui.camera_thumb;
const DrawList = ra8.gui.draw_list.DrawList;
const Color = ra8.gui.draw_list.Color;
const decoded = ra8.host.camera.decoded;

test "the longer edge fits the limit and the shape is kept" {
    try std.testing.expectEqual(.{ @as(u32, 24), @as(u32, 12) }, thumb.fit(48, 24, 24));
    try std.testing.expectEqual(.{ @as(u32, 12), @as(u32, 24) }, thumb.fit(100, 200, 24));
    try std.testing.expectEqual(.{ @as(u32, 10), @as(u32, 5) }, thumb.fit(10, 5, 24));
    try std.testing.expectEqual(.{ @as(u32, 24), @as(u32, 1) }, thumb.fit(1000, 1, 24));
}

test "each preview cell averages the pixels under it" {
    // Red is 200, 0, 0 and blue is 0, 0, 100.
    var pixels = [_]u8{ 200, 0, 0, 200, 0, 0, 0, 0, 100, 0, 0, 100, 200, 0, 0, 0, 0, 100, 0, 0, 100, 0, 0, 100 };
    const picture = decoded.Image{ .width = 4, .height = 2, .pixels = &pixels };
    const t = try thumb.shrink(std.testing.allocator, picture, 2);
    defer t.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 2), t.width);
    try std.testing.expectEqual(@as(u32, 1), t.height);
    try std.testing.expectEqual(Color.rgb(150, 0, 25), t.pixels[0]);
    try std.testing.expectEqual(Color.rgb(0, 0, 100), t.pixels[1]);
}

test "a picture file loads as its preview; anything else is refused" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ppm = "P6\n2 1\n255\n" ++ "\x0a\x14\x1e" ++ "\xc8\x00\x64";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "p.ppm", .data = ppm });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "n.txt", .data = "not a picture" });
    const t = try thumb.load(std.testing.allocator, std.testing.io, tmp.dir, "p.ppm");
    defer t.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 2), t.width);
    try std.testing.expectEqual(Color.rgb(10, 20, 30), t.pixels[0]);
    try std.testing.expectEqual(Color.rgb(200, 0, 100), t.pixels[1]);
    try std.testing.expectError(error.Unsupported, thumb.load(std.testing.allocator, std.testing.io, tmp.dir, "n.txt"));
}

test "no preview draws nothing; a preview is centred in its area" {
    var list = DrawList.init(std.testing.allocator, 200, 200);
    defer list.deinit();
    const area = ra8.gui.draw_list.Rect{ .x = 10, .y = 20, .w = 24, .h = 24 };
    try thumb.draw(&list, area, null);
    try std.testing.expectEqual(@as(usize, 0), list.commands.items.len);
    var pixels = @as([8]Color, @splat(Color.rgb(1, 2, 3)));
    try thumb.draw(&list, area, .{ .width = 4, .height = 2, .pixels = &pixels });
    try std.testing.expectEqual(@as(usize, 1), list.commands.items.len);
    const quad = list.commands.items[0].shape.image;
    try std.testing.expectEqual(@as(i32, 20), quad.area.x);
    try std.testing.expectEqual(@as(i32, 31), quad.area.y);
    try std.testing.expectEqual(@as(u32, 4), quad.image.width);
}

test "a clip previews as its first frame; a cut-short clip is refused" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const header = "YUV4MPEG2 W2 H1 F25:1 Cmono\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "c.y4m", .data = header ++ "FRAME\n\x10\xeb" ++ "FRAME\n\xeb\x10" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "short.y4m", .data = header ++ "FRAME\n\x10" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bad.y4m", .data = header ++ "JUNK\n\x10\xeb" });
    const t = try thumb.load(std.testing.allocator, std.testing.io, tmp.dir, "c.y4m");
    defer t.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 2), t.width);
    try std.testing.expectEqual(@as(u32, 1), t.height);
    try std.testing.expectEqual(Color.rgb(0, 0, 0), t.pixels[0]);
    try std.testing.expectEqual(Color.rgb(255, 255, 255), t.pixels[1]);
    try std.testing.expectError(error.Truncated, thumb.load(std.testing.allocator, std.testing.io, tmp.dir, "short.y4m"));
    try std.testing.expectError(error.BadHeader, thumb.load(std.testing.allocator, std.testing.io, tmp.dir, "bad.y4m"));
}
