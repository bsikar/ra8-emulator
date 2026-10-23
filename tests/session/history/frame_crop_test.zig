//! Tests for src/session/history/frame_crop.zig: grayscale conversion,
//! diff.box delta crop, flate level 1 compression, and bit-exact reconstruction.
const std = @import("std");
const ra8 = @import("ra8");
const crop = ra8.session.history_frame_crop;

test "argbToGray matches CCIR 601 luma formula" {
    // Pure black
    try std.testing.expectEqual(@as(u8, 0), crop.argbToGray(0xFF000000));
    // Pure white
    try std.testing.expectEqual(@as(u8, 255), crop.argbToGray(0xFFFFFFFF));
    // Red: 255 * 0.299 = ~76
    try std.testing.expectEqual(@as(u8, 76), crop.argbToGray(0xFFFF0000));
    // Green: 255 * 0.587 = ~150
    try std.testing.expectEqual(@as(u8, 150), crop.argbToGray(0xFF00FF00));
    // Blue: 255 * 0.114 = ~29
    try std.testing.expectEqual(@as(u8, 29), crop.argbToGray(0xFF0000FF));
}

test "diffBox finds exact bounding box of changed pixels" {
    const width: u32 = 100;
    const height: u32 = 50;
    const count = width * height;
    var before: [count]u8 = undefined;
    var after: [count]u8 = undefined;
    @memset(&before, 10);
    @memset(&after, 10);

    // Identical frames produce null diffBox
    try std.testing.expectEqual(@as(?crop.Rect, null), crop.diffBox(&before, &after, width));

    // Change a single pixel at (20, 15)
    after[15 * width + 20] = 50;
    const single = crop.diffBox(&before, &after, width).?;
    try std.testing.expectEqual(@as(u16, 20), single.x);
    try std.testing.expectEqual(@as(u16, 15), single.y);
    try std.testing.expectEqual(@as(u16, 1), single.width);
    try std.testing.expectEqual(@as(u16, 1), single.height);

    // Change a 10x5 block from (30, 20) to (39, 24)
    var r: usize = 20;
    while (r <= 24) : (r += 1) {
        var c: usize = 30;
        while (c <= 39) : (c += 1) {
            after[r * width + c] = 80;
        }
    }
    const box = crop.diffBox(&before, &after, width).?;
    // Leftmost is still 20 from previous change, rightmost is 39
    try std.testing.expectEqual(@as(u16, 20), box.x);
    try std.testing.expectEqual(@as(u16, 15), box.y);
    try std.testing.expectEqual(@as(u16, 20), box.width); // [20..39] = 20 cols
    try std.testing.expectEqual(@as(u16, 10), box.height); // [15..24] = 10 rows
}

test "flate-1 compress and decompress round-trip" {
    const allocator = std.testing.allocator;
    const sample = "The quick brown fox jumps over the lazy dog. 1234567890 repeating pattern ";
    var data_buf: [sample.len * 20]u8 = undefined;
    for (0..20) |i| {
        @memcpy(data_buf[i * sample.len .. (i + 1) * sample.len], sample);
    }
    const data = &data_buf;

    const compressed = try crop.compress(allocator, data);
    defer allocator.free(compressed);

    // Compressed is smaller than uncompressed
    try std.testing.expect(compressed.len < data.len);

    const decompressed = try allocator.alloc(u8, data.len);
    defer allocator.free(decompressed);

    try crop.decompress(allocator, compressed, decompressed);
    try std.testing.expectEqualStrings(data, decompressed);
}

test "crop round trip is byte-exact on 1024x600 panel" {
    const allocator = std.testing.allocator;
    const width: u32 = 1024;
    const height: u32 = 600;
    const total_pixels = width * height;

    const keyframe = try allocator.alloc(u8, total_pixels);
    defer allocator.free(keyframe);
    const current = try allocator.alloc(u8, total_pixels);
    defer allocator.free(current);

    // Fill keyframe with deterministic gradient pattern
    for (keyframe, 0..) |*p, i| {
        p.* = @truncate((i * 17) ^ (i / width));
    }
    @memcpy(current, keyframe);

    // Modify a rectangular patch on current: (x=100, y=50, width=200, height=150)
    const patch_x: usize = 100;
    const patch_y: usize = 50;
    const patch_w: usize = 200;
    const patch_h: usize = 150;

    var y: usize = 0;
    while (y < patch_h) : (y += 1) {
        var x: usize = 0;
        while (x < patch_w) : (x += 1) {
            const idx = (patch_y + y) * width + (patch_x + x);
            current[idx] = @truncate(current[idx] +% 123);
        }
    }

    // Compute diff box
    const diff = crop.diffBox(keyframe, current, width).?;
    try std.testing.expectEqual(@as(u16, patch_x), diff.x);
    try std.testing.expectEqual(@as(u16, patch_y), diff.y);
    try std.testing.expectEqual(@as(u16, patch_w), diff.width);
    try std.testing.expectEqual(@as(u16, patch_h), diff.height);

    // Extract crop
    const crop_size = @as(usize, diff.width) * diff.height;
    const crop_pixels = try allocator.alloc(u8, crop_size);
    defer allocator.free(crop_pixels);
    crop.extractCrop(current, width, diff, crop_pixels);

    // Compress crop with flate level 1
    const compressed_crop = try crop.compress(allocator, crop_pixels);
    defer allocator.free(compressed_crop);

    // Reconstruct full frame from keyframe + delta
    const reconstructed = try crop.reconstruct(allocator, keyframe, width, diff, compressed_crop);
    defer allocator.free(reconstructed);

    // Byte-exact assertion
    try std.testing.expectEqualSlices(u8, current, reconstructed);
}
