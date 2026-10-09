//! Covers src/host/camera/png_decode.zig: every colour type and all five
//! scanline filters pixel for pixel, a PNG written by another encoder, split
//! IDAT data, and each refusal.
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("png_fixture.zig");

const camera = ra8.host.camera;
const png = camera.png;
const allocator = std.testing.allocator;

/// A 2x2 RGB picture (red, green / blue, white) written by Python's zlib,
/// so the inflate and chunk walk are checked against another encoder.
const foreign = [_]u8{
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x02, 0x00, 0x00, 0x00, 0xFD, 0xD4, 0x9A,
    0x73, 0x00, 0x00, 0x00, 0x12, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0xF8, 0xCF, 0xC0, 0xC0,
    0x00, 0xC2, 0x0C, 0xFF, 0x81, 0x00, 0x00, 0x1F, 0xEE, 0x05, 0xFB, 0xF1, 0xAB, 0xBA, 0x77, 0x00,
    0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
};

/// A 3x3 RGB picture whose bytes differ row to row and column to column,
/// so every filter's predictor actually contributes.
const rgb_rows = [_]u8{
    10,  200, 30,  250, 5,  60,  128, 128, 0,
    90,  15,  255, 33,  77, 140, 0,   1,   2,
    255, 254, 253, 60,  70, 80,  199, 3,   47,
};

fn expectRgb(image: camera.decoded.Image, samples: []const u8, step: usize) !void {
    for (0..image.pixels.len / 3) |index| {
        const s = samples[index * step ..];
        try std.testing.expectEqual([3]u8{ s[0], s[1], s[2] }, image.get(index));
    }
}

test "a PNG from another encoder decodes pixel for pixel" {
    const image = try png.decode(allocator, &foreign);
    defer image.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 2), image.width);
    try expectRgb(image, &.{ 255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255 }, 3);
}

test "each scanline filter, alone and mixed, undoes to the same RGB picture" {
    const plans = [_][3]u8{ .{ 0, 0, 0 }, .{ 1, 1, 1 }, .{ 2, 2, 2 }, .{ 3, 3, 3 }, .{ 4, 4, 4 }, .{ 4, 1, 3 }, .{ 2, 3, 4 } };
    for (plans) |plan| {
        const bytes = try fixture.build(allocator, .{ .width = 3, .height = 3, .colour = 2, .pixels = &rgb_rows, .filters = &plan });
        defer allocator.free(bytes);
        const image = try png.decode(allocator, bytes);
        defer image.deinit(allocator);
        try expectRgb(image, &rgb_rows, 3);
    }
}

test "greyscale and grey+alpha spread the grey level over r, g and b" {
    const grey = [_]u8{ 0, 64, 128, 255 };
    const bytes = try fixture.build(allocator, .{ .width = 2, .height = 2, .colour = 0, .pixels = &grey, .filters = &.{ 4, 2 } });
    defer allocator.free(bytes);
    const image = try png.decode(allocator, bytes);
    defer image.deinit(allocator);
    for (grey, 0..) |level, index| try std.testing.expectEqual([3]u8{ level, level, level }, image.get(index));

    const pairs = [_]u8{ 7, 0, 99, 255, 180, 1, 33, 128 };
    const ga = try fixture.build(allocator, .{ .width = 2, .height = 2, .colour = 4, .pixels = &pairs, .filters = &.{ 1, 3 } });
    defer allocator.free(ga);
    const second = try png.decode(allocator, ga);
    defer second.deinit(allocator);
    for (0..second.pixels.len / 3) |index| {
        const level = pairs[index * 2];
        try std.testing.expectEqual([3]u8{ level, level, level }, second.get(index));
    }
}

test "RGBA drops alpha and keeps the colour" {
    const rgba = [_]u8{ 1, 2, 3, 0, 250, 251, 252, 255, 9, 8, 7, 128, 40, 50, 60, 1 };
    const bytes = try fixture.build(allocator, .{ .width = 2, .height = 2, .colour = 6, .pixels = &rgba, .filters = &.{ 4, 4 } });
    defer allocator.free(bytes);
    const image = try png.decode(allocator, bytes);
    defer image.deinit(allocator);
    try expectRgb(image, &rgba, 4);
}

test "palette pictures look each index up in PLTE" {
    const palette = [_]u8{ 255, 0, 0, 0, 255, 0, 0, 0, 255 };
    const indices = [_]u8{ 2, 0, 1, 2 };
    const bytes = try fixture.build(allocator, .{ .width = 2, .height = 2, .colour = 3, .pixels = &indices, .filters = &.{ 0, 2 }, .palette = &palette });
    defer allocator.free(bytes);
    const image = try png.decode(allocator, bytes);
    defer image.deinit(allocator);
    try expectRgb(image, &.{ 0, 0, 255, 255, 0, 0, 0, 255, 0, 0, 0, 255 }, 3);
}

test "IDAT data split across chunks is joined before inflating" {
    const bytes = try fixture.build(allocator, .{ .width = 3, .height = 3, .colour = 2, .pixels = &rgb_rows, .filters = &.{ 1, 2, 4 }, .split_idat = true });
    defer allocator.free(bytes);
    const image = try png.decode(allocator, bytes);
    defer image.deinit(allocator);
    try expectRgb(image, &rgb_rows, 3);
}

test "refusals are named" {
    try std.testing.expectError(error.BadHeader, png.decode(allocator, "P6 1 1 255\n"));
    try std.testing.expectError(error.Truncated, png.decode(allocator, foreign[0 .. foreign.len - 20]));

    var flipped = foreign;
    flipped[40] ^= 0xFF; // inside the IDAT payload, so its CRC no longer holds
    try std.testing.expectError(error.BadCrc, png.decode(allocator, &flipped));

    const cases = [_]struct { spec: fixture.Spec, err: anyerror }{
        .{ .spec = .{ .width = 1, .height = 1, .colour = 2, .pixels = &.{ 1, 2, 3 }, .filters = &.{0}, .interlace = 1 }, .err = error.Interlaced },
        .{ .spec = .{ .width = 1, .height = 1, .colour = 2, .pixels = &.{ 1, 2, 3 }, .filters = &.{0}, .depth = 16 }, .err = error.Unsupported },
        .{ .spec = .{ .width = 1, .height = 1, .colour = 1, .pixels = &.{1}, .filters = &.{0} }, .err = error.Unsupported },
        .{ .spec = .{ .width = 1, .height = 1, .colour = 2, .pixels = &.{ 1, 2, 3 }, .filters = &.{7} }, .err = error.Corrupt },
        .{ .spec = .{ .width = 1, .height = 1, .colour = 3, .pixels = &.{0}, .filters = &.{0} }, .err = error.BadHeader },
        .{ .spec = .{ .width = 1, .height = 1, .colour = 3, .pixels = &.{5}, .filters = &.{0}, .palette = &.{ 1, 2, 3 } }, .err = error.BadHeader },
        .{ .spec = .{ .width = 0, .height = 1, .colour = 2, .pixels = &.{}, .filters = &.{0} }, .err = error.BadHeader },
        .{ .spec = .{ .width = 5000, .height = 5000, .colour = 0, .pixels = &.{}, .filters = &.{}, .no_data = true }, .err = error.TooLarge },
    };
    for (cases) |case| {
        const bytes = try fixture.build(allocator, case.spec);
        defer allocator.free(bytes);
        try std.testing.expectError(case.err, png.decode(allocator, bytes));
    }
}

test "paeth picks the nearest of left, up and up-left" {
    try std.testing.expectEqual(@as(u8, 10), png.paeth(10, 20, 20));
    try std.testing.expectEqual(@as(u8, 20), png.paeth(10, 20, 10));
    try std.testing.expectEqual(@as(u8, 150), png.paeth(200, 100, 150));
}
