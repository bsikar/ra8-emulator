//! Covers src/host/camera/ppm_decode.zig: P6 and P3 pixel for pixel,
//! maxval rescaling, comments, and each refusal.
const std = @import("std");
const ra8 = @import("ra8");

const camera = ra8.host.camera;
const allocator = std.testing.allocator;

const expected = [_]u8{
    255, 0, 0,   0,   255, 0,
    0,   0, 255, 255, 255, 255,
};

test "P6 decodes a 2x2 picture with a comment in the header" {
    const file = "P6\n# a test\n2 2\n255\n" ++ "\xff\x00\x00" ++ "\x00\xff\x00" ++ "\x00\x00\xff" ++ "\xff\xff\xff";
    const image = try camera.ppm.decode(allocator, file);
    defer image.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 2), image.width);
    try std.testing.expectEqual(@as(u32, 2), image.height);
    try std.testing.expectEqualSlices(u8, &expected, image.pixels);
}

test "P3 decodes the same picture from text" {
    const file = "P3 2 2 255\n255 0 0  0 255 0\n0 0 255 255 255 255\n";
    const image = try camera.ppm.decode(allocator, file);
    defer image.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &expected, image.pixels);
}

test "a maxval below 255 rescales each sample" {
    const image = try camera.ppm.decode(allocator, "P3 1 1 15 15 0 7");
    defer image.deinit(allocator);
    try std.testing.expectEqual([3]u8{ 255, 0, 119 }, image.get(0));
}

test "bad, truncated, unsupported and oversized files are refused" {
    try std.testing.expectError(error.Truncated, camera.ppm.decode(allocator, "P6 2 2 255\n\xff\x00"));
    try std.testing.expectError(error.Unsupported, camera.ppm.decode(allocator, "P6 1 1 65535\n\x00\x00"));
    try std.testing.expectError(error.BadHeader, camera.ppm.decode(allocator, "P6 x 1 255\n"));
    try std.testing.expectError(error.BadHeader, camera.ppm.decode(allocator, "P5 1 1 255\n\x00"));
    try std.testing.expectError(error.BadHeader, camera.ppm.decode(allocator, "P6 0 1 255\n"));
    try std.testing.expectError(error.Truncated, camera.ppm.decode(allocator, "P3 1 1 255 7 7"));
    try std.testing.expectError(error.TooLarge, camera.ppm.decode(allocator, "P6 5000 5000 255\n"));
}
