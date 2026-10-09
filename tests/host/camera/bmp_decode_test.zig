//! Covers src/host/camera/bmp_decode.zig: 24-bit bottom-up and 32-bit
//! top-down pixel for pixel, row padding, and each refusal.
const std = @import("std");
const ra8 = @import("ra8");

const camera = ra8.host.camera;
const allocator = std.testing.allocator;

const expected = [_]u8{
    255, 0, 0,   0,   255, 0,
    0,   0, 255, 255, 255, 255,
};

/// A 54-byte header for a width x height picture at `bits` per pixel.
fn header(buffer: []u8, height: i32, bits: u16, compression: u32) void {
    @memset(buffer[0..54], 0);
    buffer[0] = 'B';
    buffer[1] = 'M';
    std.mem.writeInt(u32, buffer[10..14], 54, .little);
    std.mem.writeInt(u32, buffer[14..18], 40, .little);
    std.mem.writeInt(i32, buffer[18..22], 2, .little);
    std.mem.writeInt(i32, buffer[22..26], height, .little);
    std.mem.writeInt(u16, buffer[26..28], 1, .little);
    std.mem.writeInt(u16, buffer[28..30], bits, .little);
    std.mem.writeInt(u32, buffer[30..34], compression, .little);
}

test "24-bit bottom-up stores the last row first, padded to four bytes" {
    var file: [54 + 16]u8 = undefined;
    header(&file, 2, 24, 0);
    // Stored row 0 is the picture's bottom row: blue, white, then 2 pad bytes.
    @memcpy(file[54..62], "\xff\x00\x00\xff\xff\xff\x00\x00");
    @memcpy(file[62..70], "\x00\x00\xff\x00\xff\x00\x00\x00");
    const image = try camera.bmp.decode(allocator, &file);
    defer image.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &expected, image.pixels);
}

test "32-bit top-down reads rows in order and ignores the fourth byte" {
    var file: [54 + 16]u8 = undefined;
    header(&file, -2, 32, 0);
    @memcpy(file[54..62], "\x00\x00\xff\x7f\x00\xff\x00\x7f");
    @memcpy(file[62..70], "\xff\x00\x00\x7f\xff\xff\xff\x7f");
    const image = try camera.bmp.decode(allocator, &file);
    defer image.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &expected, image.pixels);
}

test "compressed, paletted, truncated and malformed files are refused" {
    var file: [54 + 16]u8 = undefined;
    header(&file, 2, 24, 1);
    try std.testing.expectError(error.Unsupported, camera.bmp.decode(allocator, &file));
    header(&file, 2, 8, 0);
    try std.testing.expectError(error.Unsupported, camera.bmp.decode(allocator, &file));
    header(&file, 2, 24, 0);
    try std.testing.expectError(error.Truncated, camera.bmp.decode(allocator, file[0..60]));
    try std.testing.expectError(error.Truncated, camera.bmp.decode(allocator, file[0..20]));
    header(&file, 0, 24, 0);
    try std.testing.expectError(error.BadHeader, camera.bmp.decode(allocator, &file));
    try std.testing.expectError(error.BadHeader, camera.bmp.decode(allocator, "XX"));
}
