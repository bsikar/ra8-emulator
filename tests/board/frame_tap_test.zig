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
