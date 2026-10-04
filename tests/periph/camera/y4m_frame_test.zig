//! Covers src/periph/camera/y4m_frame.zig: BT.601 studio-range planes
//! turned into RGB, with each chroma sample covering the luma under it.
const std = @import("std");
const ra8 = @import("ra8");

const video = ra8.periph.ceu.camera.video;
const Rgb = ra8.periph.ceu.camera.convert.Rgb;

test "studio black, white and red come back as full-range RGB" {
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 0 }, video.yuv.rgb(16, 128, 128));
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 255, .b = 255 }, video.yuv.rgb(235, 128, 128));
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 0, .b = 0 }, video.yuv.rgb(81, 90, 240));
}

test "a 4:2:0 frame shares one chroma sample over each 2x2 block" {
    const header = try video.y4m.parse("YUV4MPEG2 W2 H2 C420");
    const planes = [_]u8{ 81, 81, 81, 81, 90, 240 };
    var out: [4]Rgb = undefined;
    video.yuv.toRgb(header, &planes, &out);
    for (out) |pixel| try std.testing.expectEqual(Rgb{ .r = 255, .g = 0, .b = 0 }, pixel);
}

test "a mono frame is grey, a 4:4:4 frame has chroma per pixel" {
    const mono = try video.y4m.parse("YUV4MPEG2 W2 H1 Cmono");
    var grey: [2]Rgb = undefined;
    video.yuv.toRgb(mono, &[_]u8{ 16, 235 }, &grey);
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 0 }, grey[0]);
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 255, .b = 255 }, grey[1]);
    const full = try video.y4m.parse("YUV4MPEG2 W2 H1 C444");
    var colour: [2]Rgb = undefined;
    video.yuv.toRgb(full, &[_]u8{ 81, 235, 90, 128, 240, 128 }, &colour);
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 0, .b = 0 }, colour[0]);
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 255, .b = 255 }, colour[1]);
}
