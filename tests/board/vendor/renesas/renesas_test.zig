//! Covers src/board/vendor/renesas/renesas.zig: Renesas board wiring exports.
const ra8 = @import("ra8");
const std = @import("std");

test "renesas board namespace exports FPB-RA8E1 and FPB-RA4T1 wiring" {
    try std.testing.expect(@TypeOf(ra8.board.vendor.renesas.fpb_ra8e1.attach) != void);
    try std.testing.expect(@TypeOf(ra8.board.vendor.renesas.fpb_ra4t1.bind) != void);
    try std.testing.expect(@TypeOf(ra8.board.vendor.renesas.fpb_ra4t1.tick) != void);
}
