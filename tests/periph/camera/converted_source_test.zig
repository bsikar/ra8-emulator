//! Covers src/periph/camera/converted_source.zig: a CEU on a converted
//! source captures the programmed format and size, not the gradient.
const std = @import("std");
const ra8 = @import("ra8");

const camera = ra8.periph.ceu.camera;
const Rgb = camera.convert.Rgb;

const red = Rgb{ .r = 255, .g = 0, .b = 0 };
const blue = Rgb{ .r = 0, .g = 0, .b = 255 };

test "a converted source fills lines in RGB565, scaled to the shape" {
    const pixels = [_]Rgb{ red, blue };
    var converted = camera.converted.Converted{
        .input = .{ .width = 2, .height = 1, .pixels = &pixels },
        .format = .rgb565,
    };
    const source = converted.source();
    source.frame(0, .{ .width = 8, .lines = 2 });
    var line: [8]u8 = undefined;
    source.fill(1, 0, &line);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0xF8, 0x00, 0xF8, 0x1F, 0x00, 0x1F, 0x00 }, &line);
    var tail: [3]u8 = undefined;
    source.fill(0, 5, &tail);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x1F, 0x00 }, &tail);
    source.close();
}

test "a converted source fills lines in YUYV" {
    const pixels = [_]Rgb{red};
    var converted = camera.converted.Converted{
        .input = .{ .width = 1, .height = 1, .pixels = &pixels },
        .format = .yuv422,
    };
    const source = converted.source();
    source.frame(0, .{ .width = 4, .lines = 1 });
    var line: [4]u8 = undefined;
    source.fill(0, 0, &line);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 82, 90, 82, 240 }, &line);
}
