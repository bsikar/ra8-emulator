//! Tests for the LCD pane's frame history (RA8EMU-825): reconstruction from
//! keyframe plus deltas, eviction within the caps, and scrubbing by virtual
//! timestamp.
const std = @import("std");
const gui_app = @import("gui_app");
const lcd_history = gui_app.lcd_history;

const W: u32 = 8;
const H: u32 = 4;

fn blank(allocator: std.mem.Allocator) ![]u8 {
    const image = try allocator.alloc(u8, W * H);
    @memset(image, 0);
    return image;
}

fn rect(allocator: std.mem.Allocator, x: u32, y: u32, w: u32, h: u32, gray: u8) !lcd_history.Delta {
    const pixels = try allocator.alloc(u8, w * h);
    @memset(pixels, gray);
    return .{ .x = x, .y = y, .w = w, .h = h, .pixels = pixels };
}

test "reconstructing a delta frame matches the image as captured" {
    const allocator = std.testing.allocator;
    var history = lcd_history.History.init(allocator);
    defer history.deinit();
    history.width = W;
    history.height = H;

    const full1 = try blank(allocator);
    defer allocator.free(full1);
    const d1 = try rect(allocator, 0, 0, 2, 2, 7);
    defer allocator.free(d1.pixels);
    try history.push(100, full1, &.{d1});

    const full2 = try blank(allocator);
    defer allocator.free(full2);
    @memset(full2[0..2], 7);
    @memset(full2[8..10], 7);
    @memset(full2[20..22], 9);
    const d2 = try rect(allocator, 4, 2, 2, 1, 9);
    defer allocator.free(d2.pixels);
    // The second frame's deltas are the full diff against the first: the
    // seven region is still part of what changed between the two captures.
    try history.push(200, full2, &.{ d1, d2 });

    const built = try blank(allocator);
    defer allocator.free(built);
    history.reconstruct(1, built);
    try std.testing.expectEqualSlices(u8, full2, built);
    history.reconstruct(0, built);
    try std.testing.expectEqualSlices(u8, full1, built);
}

test "a keyframe boundary keeps reconstruction across segments right" {
    const allocator = std.testing.allocator;
    var history = lcd_history.History.init(allocator);
    defer history.deinit();
    history.width = W;
    history.height = H;

    var latest: ?[]u8 = null;
    defer if (latest) |image| allocator.free(image);
    for (0..lcd_history.keyframe_every + 2) |i| {
        const gray: u8 = @intCast(i + 1);
        const image = try blank(allocator);
        @memset(image, gray);
        const delta = try rect(allocator, 0, 0, W, H, gray);
        defer allocator.free(delta.pixels);
        try history.push(@intCast((i + 1) * 10), image, &.{delta});
        if (latest) |old| allocator.free(old);
        latest = image;
    }

    const built = try blank(allocator);
    defer allocator.free(built);
    history.reconstruct(history.frames - 1, built);
    try std.testing.expectEqualSlices(u8, latest.?, built);
    // The segment boundary carries a fresh keyframe: the first frame of the
    // second segment reconstructs from it, not from the first segment.
    const boundary = lcd_history.keyframe_every;
    history.reconstruct(boundary, built);
    try std.testing.expectEqual(@as(u8, @intCast(boundary + 1)), built[0]);
}

test "the ring evicts the oldest segment within the frame cap" {
    const allocator = std.testing.allocator;
    var history = lcd_history.History.init(allocator);
    defer history.deinit();
    history.width = W;
    history.height = H;
    history.max_frames = 6;

    var latest: ?[]u8 = null;
    defer if (latest) |image| allocator.free(image);
    for (0..10) |i| {
        const gray: u8 = @intCast(i + 1);
        const image = try blank(allocator);
        @memset(image, gray);
        const delta = try rect(allocator, 0, 0, W, H, gray);
        defer allocator.free(delta.pixels);
        try history.push(@intCast((i + 1) * 10), image, &.{delta});
        if (latest) |old| allocator.free(old);
        latest = image;
    }

    try std.testing.expect(history.frames <= 6);
    const built = try blank(allocator);
    defer allocator.free(built);
    history.reconstruct(history.frames - 1, built);
    try std.testing.expectEqualSlices(u8, latest.?, built);
    // Whole-segment eviction keeps 70..100 (four frames) under the cap of
    // six; the oldest surviving stamp is 70.
    try std.testing.expectEqual(@as(u64, 70), history.stampAt(0).?);
}

test "scrubbing by virtual timestamp picks the right frame" {
    const allocator = std.testing.allocator;
    var history = lcd_history.History.init(allocator);
    defer history.deinit();
    history.width = W;
    history.height = H;

    for (0..3) |i| {
        const image = try blank(allocator);
        defer allocator.free(image);
        const delta = try rect(allocator, 0, 0, 1, 1, @intCast(i + 1));
        defer allocator.free(delta.pixels);
        try history.push(@intCast((i + 1) * 100), image, &.{delta});
    }

    try std.testing.expectEqual(@as(?usize, 0), history.scrub(100));
    try std.testing.expectEqual(@as(?usize, 1), history.scrub(250));
    try std.testing.expectEqual(@as(?usize, 2), history.scrub(300));
    try std.testing.expectEqual(@as(?usize, 2), history.scrub(500));
    try std.testing.expectEqual(@as(?usize, null), history.scrub(50));
}

test "stepping moves frame by frame and clamps at both ends" {
    const allocator = std.testing.allocator;
    var history = lcd_history.History.init(allocator);
    defer history.deinit();
    history.width = W;
    history.height = H;

    for (0..3) |i| {
        const image = try blank(allocator);
        defer allocator.free(image);
        try history.push(@intCast((i + 1) * 100), image, &.{});
    }

    try std.testing.expectEqual(@as(?usize, 2), history.step(0, 2));
    try std.testing.expectEqual(@as(?usize, 2), history.step(0, 9));
    try std.testing.expectEqual(@as(?usize, 0), history.step(2, -9));
    try std.testing.expectEqual(@as(?usize, 0), history.step(1, -1));
    try std.testing.expectEqual(@as(?usize, 0), history.step(0, 0));
}

test "the byte cap evicts the oldest segment too" {
    const allocator = std.testing.allocator;
    var history = lcd_history.History.init(allocator);
    defer history.deinit();
    history.width = W;
    history.height = H;
    history.max_bytes = W * H * 3;

    for (0..8) |i| {
        const image = try blank(allocator);
        defer allocator.free(image);
        const delta = try rect(allocator, 0, 0, 1, 1, @intCast(i + 1));
        defer allocator.free(delta.pixels);
        try history.push(@intCast((i + 1) * 10), image, &.{delta});
    }

    try std.testing.expect(history.bytes <= W * H * 3 + W * H);
    try std.testing.expect(history.segments.items.len >= 1);
    const built = try blank(allocator);
    defer allocator.free(built);
    history.reconstruct(history.frames - 1, built);
    try std.testing.expectEqual(@as(u8, 8), built[0]);
}
