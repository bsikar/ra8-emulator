//! Covers src/session/history/frame_decoder.zig: reverse clock with wall delta,
//! speed changes without restart, honest throughput limits, hysteresis
//! transitions between smooth and keyframes-only, presentation buckets, and
//! frame lookup source hierarchy.
const std = @import("std");
const ra8 = @import("ra8");
const decoder_mod = ra8.session.history_frame_decoder;
const cache_mod = ra8.session.history_frame_cache;
const pic_mod = ra8.session.history_checkpoint_picture;
const fx = @import("frame_fixture.zig");

test "reverse clock decrements virtual time at 1x, 8x, and 32x speed" {
    const gpa = std.testing.allocator;
    var dec = decoder_mod.FrameDecoder.init(gpa);
    defer dec.deinit();

    const initial_ns: u64 = 1_000_000_000;
    const dt_wall_ns: u64 = 16_666_667; // ~60 Hz display tick

    // 1x speed
    dec.setCursorNs(initial_ns);
    dec.setSpeed(1.0);
    var res = try dec.tick(dt_wall_ns);
    try std.testing.expectEqual(initial_ns - dt_wall_ns, res.cursor_ns);
    try std.testing.expectEqual(decoder_mod.Status.ok, res.status);

    // 8x speed
    dec.setCursorNs(initial_ns);
    dec.setSpeed(8.0);
    res = try dec.tick(dt_wall_ns);
    const expected_8x = initial_ns - (dt_wall_ns * 8);
    try std.testing.expectEqual(expected_8x, res.cursor_ns);

    // 32x speed
    dec.setCursorNs(initial_ns);
    dec.setSpeed(32.0);
    res = try dec.tick(dt_wall_ns);
    const expected_32x = initial_ns - (dt_wall_ns * 32);
    try std.testing.expectEqual(expected_32x, res.cursor_ns);

    // Reaching zero stops at history_start
    dec.setCursorNs(100);
    res = try dec.tick(dt_wall_ns);
    try std.testing.expectEqual(@as(u64, 0), res.cursor_ns);
    try std.testing.expectEqual(decoder_mod.Status.history_start, res.status);
}

test "speed change takes effect next tick without resetting decoded state" {
    const gpa = std.testing.allocator;
    var dec = decoder_mod.FrameDecoder.init(gpa);
    defer dec.deinit();

    dec.setCursorNs(1_000_000_000);
    dec.setSpeed(1.0);

    const dt: u64 = 10_000_000; // 10 ms
    _ = try dec.tick(dt);
    try std.testing.expectEqual(@as(u64, 990_000_000), dec.cursor_ns);

    // Change speed to 4x on the next tick
    dec.setSpeed(4.0);
    _ = try dec.tick(dt);
    // 990 ms - (10 ms * 4) = 950 ms
    try std.testing.expectEqual(@as(u64, 950_000_000), dec.cursor_ns);
}

test "honest throughput limit bounds uncached reverse playback" {
    // Honest throughput: min(speed, 0.8 * R / (1 + restore/segment))
    // Example: R = 50.0 (replay 50x real-time), restore/segment = 0.25 (restore takes 25% of replay time)
    // max_honest = 0.8 * 50.0 / 1.25 = 32.0
    const limit1 = decoder_mod.honestThroughputLimit(100.0, 50.0, 0.25);
    try std.testing.expectApproxEqAbs(@as(f64, 32.0), limit1, 0.001);

    // If requested speed is lower than honest limit, requested speed is used
    const limit2 = decoder_mod.honestThroughputLimit(16.0, 50.0, 0.25);
    try std.testing.expectApproxEqAbs(@as(f64, 16.0), limit2, 0.001);

    // At 1x speed, 1x is honored
    const limit3 = decoder_mod.honestThroughputLimit(1.0, 10.0, 0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), limit3, 0.001);
}

test "hysteresis state machine transitions at 0.5s lag and 2.0s lead" {
    const gpa = std.testing.allocator;
    var dec = decoder_mod.FrameDecoder.init(gpa);
    defer dec.deinit();

    const ms = std.time.ns_per_ms;

    try std.testing.expectEqual(decoder_mod.PresentationMode.smooth, dec.mode);

    // Falling behind 400 ms: still smooth
    try std.testing.expectEqual(decoder_mod.PresentationMode.smooth, dec.updateHysteresis(400 * ms));

    // Falling behind 100 ms more (total 500 ms): switches to keyframes_only
    try std.testing.expectEqual(decoder_mod.PresentationMode.keyframes_only, dec.updateHysteresis(100 * ms));

    // Getting ahead 1500 ms: still in keyframes_only
    try std.testing.expectEqual(decoder_mod.PresentationMode.keyframes_only, dec.updateHysteresis(-1500 * ms));

    // Getting ahead 500 ms more (total 2000 ms lead): switches back to smooth
    try std.testing.expectEqual(decoder_mod.PresentationMode.smooth, dec.updateHysteresis(-500 * ms));

    // Max speed always forces keyframes_only
    dec.setMaxSpeed();
    try std.testing.expectEqual(decoder_mod.PresentationMode.keyframes_only, dec.mode);
    try std.testing.expectEqual(decoder_mod.PresentationMode.keyframes_only, dec.updateHysteresis(-5000 * ms));
}

test "presentation buckets retain the last frame of each bucket window" {
    const gpa = std.testing.allocator;
    var dec = decoder_mod.FrameDecoder.init(gpa);
    defer dec.deinit();

    // At 1x speed, bucket width is ~16_666_667 ns (~16.6 ms)
    dec.setSpeed(1.0);
    try dec.prepareBuckets(0, 50_000_000); // 3 buckets: [0, 16.6ms), [16.6ms, 33.3ms), [33.3ms, 50ms)
    try std.testing.expectEqual(@as(usize, 3), dec.buckets.items.len);

    const px1 = try gpa.alloc(u8, 4);
    @memset(px1, 10);
    const px2 = try gpa.alloc(u8, 4);
    @memset(px2, 20);

    // Store frame at 5 ms into bucket 0
    try dec.storeBucketFrame(.{
        .position = .{ .branch = 0, .r = 1, .phase = .board, .o = 0 },
        .virtual_ns = 5_000_000,
        .width = 2,
        .height = 2,
        .pixels = px1,
        .source = .decoded_segment,
    });
    gpa.free(px1);

    // Store later frame at 12 ms into bucket 0: replaces the earlier frame
    try dec.storeBucketFrame(.{
        .position = .{ .branch = 0, .r = 2, .phase = .board, .o = 0 },
        .virtual_ns = 12_000_000,
        .width = 2,
        .height = 2,
        .pixels = px2,
        .source = .decoded_segment,
    });
    gpa.free(px2);

    // Bucket 0 should now hold the frame at 12 ms
    const b0 = dec.buckets.items[0];
    try std.testing.expect(b0.frame != null);
    try std.testing.expectEqual(@as(u64, 12_000_000), b0.frame.?.virtual_ns);
    try std.testing.expectEqual(@as(u8, 20), b0.frame.?.pixels[0]);
}

test "frame lookup honors source hierarchy: cache -> bucket -> checkpoint picture" {
    const gpa = std.testing.allocator;
    var dec = decoder_mod.FrameDecoder.init(gpa);
    defer dec.deinit();

    // 1. Decoded segment bucket frame
    const px_b = try gpa.alloc(u8, 4);
    @memset(px_b, 42);
    defer gpa.free(px_b);

    try dec.prepareBuckets(0, 20_000_000);
    try dec.storeBucketFrame(.{
        .position = .{ .branch = 0, .r = 1, .phase = .board, .o = 0 },
        .virtual_ns = 10_000_000,
        .width = 2,
        .height = 2,
        .pixels = px_b,
        .source = .decoded_segment,
    });

    var hit = try dec.lookupFrame(15_000_000);
    try std.testing.expect(hit != null);
    defer hit.?.deinit(gpa);
    try std.testing.expectEqual(decoder_mod.SourceKind.decoded_segment, hit.?.source);
    try std.testing.expectEqual(@as(u8, 42), hit.?.pixels[0]);

    // 2. Now attach a frame cache with a frame at 12 ms: frame cache wins over bucket
    var cache = cache_mod.FrameCache.init(gpa, std.testing.io, .{ .ram_bytes = 1 << 20 }, null);
    defer cache.deinit();

    const pic_key = fx.picture(2, 0);
    try fx.put(&cache, gpa, try fx.keyRecord(gpa, fx.at(0, 12_000), &pic_key));
    dec.bindCache(&cache);

    var cache_hit = try dec.lookupFrameAt(15_000_000, fx.at(0, 15_000));
    try std.testing.expect(cache_hit != null);
    defer cache_hit.?.deinit(gpa);
    try std.testing.expectEqual(decoder_mod.SourceKind.frame_cache, cache_hit.?.source);
}
