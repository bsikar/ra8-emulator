//! Covers src/board/vendor/himax/himax.zig: Himax board package exports.
const ra8 = @import("ra8");
const std = @import("std");

const himax_board = ra8.board.vendor.himax;

test "Himax board namespace exposes Grove Vision AI V2 timer frequency" {
    try std.testing.expectEqual(@as(u64, 24_000_000), himax_board.grove_vision_ai_v2.timer_hz);
}
