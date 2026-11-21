//! Covers src/board/vendor.zig: vendor board wiring namespace exports.
const ra8 = @import("ra8");
const std = @import("std");

test "vendor board namespace exports Renesas and Himax board wiring" {
    try std.testing.expect(@TypeOf(ra8.board.vendor.renesas.fpb_ra8e1.attach) != void);
    try std.testing.expect(@TypeOf(ra8.board.vendor.renesas.fpb_ra4t1.attachBlocks) != void);
    try std.testing.expectEqual(@as(u64, 24_000_000), ra8.board.vendor.himax.grove_vision_ai_v2.timer_hz);
}
