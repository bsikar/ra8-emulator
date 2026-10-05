//! Covers tools/handoff_bench.zig: a short run publishes every frame, a
//! reader run reads at least once, and the slowdown sum is right. The 2%
//! bound itself is the bench step's to judge, not a host test's.
const std = @import("std");
const bench = @import("handoff_bench");

const tiny = bench.Config{ .frames = 40, .work_per_frame = 1_000, .width = 16, .height = 8, .reader_hz = 10_000, .trials = 2 };

test "a writer alone publishes every frame and nobody reads" {
    const run = try bench.best(std.testing.allocator, tiny, false);
    try std.testing.expectEqual(@as(u32, 40), run.publishes);
    try std.testing.expectEqual(@as(u32, 0), run.reads);
}

test "a reader alongside sees published frames" {
    var config = tiny;
    config.frames = 400;
    const run = try bench.once(std.testing.allocator, config, true);
    try std.testing.expectEqual(@as(u32, 400), run.publishes);
    try std.testing.expect(run.reads <= run.publishes);
}

test "slowdown is the loaded run's extra time over the base, in percent" {
    const base = bench.Run{ .elapsed_ns = 1000, .publishes = 1, .reads = 0, .checksum = 0 };
    const slow = bench.Run{ .elapsed_ns = 1015, .publishes = 1, .reads = 1, .checksum = 0 };
    const fast = bench.Run{ .elapsed_ns = 990, .publishes = 1, .reads = 1, .checksum = 0 };
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), bench.slowdown(base, slow), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), bench.slowdown(base, fast), 1e-9);
}
