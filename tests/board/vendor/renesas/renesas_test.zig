//! Covers src/board/vendor/renesas/renesas.zig: Renesas board wiring exports.
const ra8 = @import("ra8");
const std = @import("std");

test "renesas board namespace exports FPB-RA8E1 wiring" {
    try std.testing.expect(@TypeOf(ra8.board.vendor.renesas.fpb_ra8e1.attach) != void);
}
