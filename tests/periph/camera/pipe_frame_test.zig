//! Covers src/periph/camera/pipe_frame.zig: the `PATH,WxH,FORMAT` argument
//! and each raw frame layout widened to RGB.
const std = @import("std");
const ra8 = @import("ra8");

const raw = ra8.periph.ceu.camera.pipe.raw;
const Rgb = ra8.periph.ceu.camera.convert.Rgb;

test "the argument splits from the right so a path may hold commas" {
    const arg = try raw.parseArg("/tmp/a,b.fifo,640x480,yuyv");
    try std.testing.expectEqualStrings("/tmp/a,b.fifo", arg.path);
    try std.testing.expectEqual(@as(u32, 640), arg.width);
    try std.testing.expectEqual(@as(u32, 480), arg.height);
    try std.testing.expectEqual(raw.Format.yuyv, arg.format);
    try std.testing.expectEqual(@as(usize, 640 * 480 * 2), arg.frameBytes());
    const stdin = try raw.parseArg("-,2x1,rgb24");
    try std.testing.expectEqualStrings("-", stdin.path);
    try std.testing.expectEqual(@as(usize, 6), stdin.frameBytes());
}

test "a missing path, size or format, or a size no frame can have, is refused" {
    const bad = [_][]const u8{
        "",             "-",          "-,2x2",             ",2x2,rgb24", "-,2x2,nv12", "-,2by2,rgb24", "-,0x2,rgb24",
        "-,2x0,rgb565", "-,3x2,yuyv", "-,5000x5000,rgb24", "-,x2,rgb24",
    };
    for (bad) |text| try std.testing.expectError(error.BadValue, raw.parseArg(text));
}

test "rgb24 is three bytes a pixel in R, G, B order" {
    var out: [2]Rgb = undefined;
    raw.toRgb(.rgb24, &.{ 1, 2, 3, 250, 251, 252 }, &out);
    try std.testing.expectEqual(Rgb{ .r = 1, .g = 2, .b = 3 }, out[0]);
    try std.testing.expectEqual(Rgb{ .r = 250, .g = 251, .b = 252 }, out[1]);
}

test "rgb565 is little-endian and widens to full-scale 8-bit channels" {
    var out: [3]Rgb = undefined;
    raw.toRgb(.rgb565, &.{ 0x00, 0xF8, 0xE0, 0x07, 0xFF, 0xFF }, &out);
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 0, .b = 0 }, out[0]);
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 255, .b = 0 }, out[1]);
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 255, .b = 255 }, out[2]);
}

test "yuyv shares one chroma pair between two pixels, studio range" {
    var out: [4]Rgb = undefined;
    raw.toRgb(.yuyv, &.{ 16, 128, 235, 128, 81, 90, 81, 240 }, &out);
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 0 }, out[0]);
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 255, .b = 255 }, out[1]);
    try std.testing.expectEqual(out[2], out[3]);
    try std.testing.expect(out[2].r > 240 and out[2].g < 16 and out[2].b < 16);
}
