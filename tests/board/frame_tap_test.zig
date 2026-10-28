//! Tests for src/board/frame_tap.zig: a passive per-boundary capture that
//! rate-caps itself in host time, and never arms the panel's clock (RA8EMU
//! M7: the tap is a consumer, not a grid edge).
const std = @import("std");
const ra8 = @import("ra8");
const frame_tap = ra8.board.frame_tap;

var captures: u32 = 0;
var captured_at: u64 = 0;
fn onCapture(_: *anyopaque, when_ns: u64) void {
    captures += 1;
    captured_at = when_ns;
}

test "the first boundary captures and the host cap holds the next ones back" {
    captures = 0;
    var tap: frame_tap.Tap = .{ .io = std.testing.io, .context = undefined, .captureFn = onCapture, .interval_ns = 1_000_000 };
    tap.afterBoundary(1);
    try std.testing.expectEqual(@as(u32, 1), captures);
    // The second boundary lands microseconds later in host time.
    tap.afterBoundary(2);
    try std.testing.expectEqual(@as(u32, 1), captures);
    // A zero interval takes every boundary (the setting tests drive by).
    tap.interval_ns = 0;
    tap.afterBoundary(3);
    try std.testing.expectEqual(@as(u32, 2), captures);
}

test "the capture carries the boundary's virtual time" {
    captures = 0;
    var tap: frame_tap.Tap = .{ .io = std.testing.io, .context = undefined, .captureFn = onCapture, .interval_ns = 0 };
    tap.afterBoundary(7_654_321);
    try std.testing.expectEqual(@as(u32, 1), captures);
    try std.testing.expectEqual(@as(u64, 7_654_321), captured_at);
}

var fan_captures_1: u32 = 0;
var fan_captures_2: u32 = 0;
fn onFanCapture1(_: *anyopaque, _: u64) void {
    fan_captures_1 += 1;
}
fn onFanCapture2(_: *anyopaque, _: u64) void {
    fan_captures_2 += 1;
}

test "fan-out dispatches boundary to multiple subscribers" {
    fan_captures_1 = 0;
    fan_captures_2 = 0;
    var fan: frame_tap.FanOut = .{};
    try std.testing.expect(fan.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), fan.count());

    var tap1: frame_tap.Tap = .{ .io = std.testing.io, .context = undefined, .captureFn = onFanCapture1, .interval_ns = 0 };
    var tap2: frame_tap.Tap = .{ .io = std.testing.io, .context = undefined, .captureFn = onFanCapture2, .interval_ns = 0 };

    try std.testing.expect(fan.add(&tap1));
    try std.testing.expect(fan.add(&tap2));
    try std.testing.expect(!fan.isEmpty());
    try std.testing.expectEqual(@as(usize, 2), fan.count());
    try std.testing.expect(fan.contains(&tap1));
    try std.testing.expect(fan.contains(&tap2));

    fan.afterBoundary(100);
    try std.testing.expectEqual(@as(u32, 1), fan_captures_1);
    try std.testing.expectEqual(@as(u32, 1), fan_captures_2);

    fan.remove(&tap1);
    try std.testing.expectEqual(@as(usize, 1), fan.count());
    try std.testing.expect(!fan.contains(&tap1));
    try std.testing.expect(fan.contains(&tap2));

    fan.afterBoundary(200);
    try std.testing.expectEqual(@as(u32, 1), fan_captures_1);
    try std.testing.expectEqual(@as(u32, 2), fan_captures_2);

    fan.remove(&tap2);
    try std.testing.expect(fan.isEmpty());
}

test "fan-out duplicate add and capacity limits" {
    var fan: frame_tap.FanOut = .{};
    var tap1: frame_tap.Tap = .{ .io = std.testing.io, .context = undefined, .captureFn = onFanCapture1, .interval_ns = 0 };
    var tap2: frame_tap.Tap = .{ .io = std.testing.io, .context = undefined, .captureFn = onFanCapture1, .interval_ns = 0 };
    var tap3: frame_tap.Tap = .{ .io = std.testing.io, .context = undefined, .captureFn = onFanCapture1, .interval_ns = 0 };
    var tap4: frame_tap.Tap = .{ .io = std.testing.io, .context = undefined, .captureFn = onFanCapture1, .interval_ns = 0 };
    var tap5: frame_tap.Tap = .{ .io = std.testing.io, .context = undefined, .captureFn = onFanCapture1, .interval_ns = 0 };

    try std.testing.expect(fan.add(&tap1));
    try std.testing.expect(fan.add(&tap1));
    try std.testing.expectEqual(@as(usize, 1), fan.count());

    try std.testing.expect(fan.add(&tap2));
    try std.testing.expect(fan.add(&tap3));
    try std.testing.expect(fan.add(&tap4));
    try std.testing.expectEqual(@as(usize, 4), fan.count());
    try std.testing.expect(!fan.add(&tap5));
}
