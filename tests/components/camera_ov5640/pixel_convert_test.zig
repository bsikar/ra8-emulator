//! Covers src/components/camera_ov5640/pixel_convert.zig: known colours to known
//! RGB565 and YUYV bytes, and nearest-neighbour scaling up and down.
const std = @import("std");
const ra8 = @import("ra8");

const convert = ra8.components.camera.convert;
const Rgb = convert.Rgb;

const red = Rgb{ .r = 255, .g = 0, .b = 0 };
const white = Rgb{ .r = 255, .g = 255, .b = 255 };
const black = Rgb{ .r = 0, .g = 0, .b = 0 };
const blue = Rgb{ .r = 0, .g = 0, .b = 255 };

test "RGB565 packs 5-6-5 little-endian" {
    try std.testing.expectEqual([2]u8{ 0x00, 0xF8 }, convert.rgb565(red));
    try std.testing.expectEqual([2]u8{ 0xFF, 0xFF }, convert.rgb565(white));
    try std.testing.expectEqual([2]u8{ 0x00, 0x00 }, convert.rgb565(black));
    try std.testing.expectEqual([2]u8{ 0x1F, 0x00 }, convert.rgb565(blue));
    try std.testing.expectEqual([2]u8{ 0xE0, 0x07 }, convert.rgb565(.{ .r = 0, .g = 255, .b = 0 }));
}

test "YUYV uses BT.601 studio range" {
    try std.testing.expectEqual([4]u8{ 235, 128, 235, 128 }, convert.yuyv(white, white));
    try std.testing.expectEqual([4]u8{ 16, 128, 16, 128 }, convert.yuyv(black, black));
    try std.testing.expectEqual([4]u8{ 82, 90, 82, 240 }, convert.yuyv(red, red));
}

test "YUYV averages chroma over the pair and keeps each luma" {
    const pair = convert.yuyv(red, blue);
    try std.testing.expectEqual(@as(u8, 82), pair[0]);
    try std.testing.expectEqual(convert.luma(blue), pair[2]);
    const u = @divFloor(convert.blueDiff(red) + convert.blueDiff(blue), 2);
    try std.testing.expectEqual(@as(u8, @intCast(u)), pair[1]);
}

const quad = [_]u8{ 255, 0, 0, 255, 255, 255, 0, 0, 0, 0, 0, 255 };
const two_by_two = convert.Frame{ .width = 2, .height = 2, .pixels = &quad };

test "scaling up repeats each source pixel" {
    try std.testing.expectEqual(red, convert.sample(two_by_two, 0, 0, 4, 4));
    try std.testing.expectEqual(red, convert.sample(two_by_two, 1, 1, 4, 4));
    try std.testing.expectEqual(white, convert.sample(two_by_two, 2, 0, 4, 4));
    try std.testing.expectEqual(black, convert.sample(two_by_two, 1, 2, 4, 4));
    try std.testing.expectEqual(blue, convert.sample(two_by_two, 3, 3, 4, 4));
}

test "scaling down picks the nearest source pixel" {
    try std.testing.expectEqual(red, convert.sample(two_by_two, 0, 0, 1, 1));
    const wide = [_]u8{ 255, 0, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255, 0, 0, 0, 0, 0, 0, 0, 0, 255, 0, 0, 255 };
    const strip = convert.Frame{ .width = 8, .height = 1, .pixels = &wide };
    try std.testing.expectEqual(red, convert.sample(strip, 0, 0, 4, 1));
    try std.testing.expectEqual(white, convert.sample(strip, 1, 0, 4, 1));
    try std.testing.expectEqual(black, convert.sample(strip, 2, 0, 4, 1));
    try std.testing.expectEqual(blue, convert.sample(strip, 3, 0, 4, 1));
}

test "byteAt walks a line in the programmed format" {
    // 2 pixels wide (4 bytes), 2 lines; the frame is 2x2, so no scaling.
    try std.testing.expectEqual(@as(u8, 0x00), convert.byteAt(two_by_two, .rgb565, 0, 0, 4, 2));
    try std.testing.expectEqual(@as(u8, 0xF8), convert.byteAt(two_by_two, .rgb565, 0, 1, 4, 2));
    try std.testing.expectEqual(@as(u8, 0xFF), convert.byteAt(two_by_two, .rgb565, 0, 2, 4, 2));
    try std.testing.expectEqual(@as(u8, 0x1F), convert.byteAt(two_by_two, .rgb565, 1, 2, 4, 2));
    try std.testing.expectEqual(@as(u8, 16), convert.byteAt(two_by_two, .yuv422, 1, 0, 4, 2));
    try std.testing.expectEqual(@as(u8, 0), convert.byteAt(two_by_two, .rgb565, 0, 4, 5, 2));
}
