//! Unit tests for RA4T1 `MSTP` (`0x4008_4000`) and bus gating.
const ra8 = @import("ra8");
const std = @import("std");

const mstp = ra8.chip.vendor.renesas.ra4t1.mstp;

test "MSTP reset values and peripheral gating match RA4T1 HUM Ch 10" {
    var unit = mstp.Mstp.init();
    try std.testing.expectEqual(@as(u32, 0xFFBF_FF7E), unit.read(mstp.win_base + mstp.ofs.a, 4));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), unit.read(mstp.win_base + mstp.ofs.b, 4));
    try std.testing.expect(!unit.sciActive(1));
    try std.testing.expect(unit.isStoppedAddress(0x4011_8900));
    try std.testing.expect(unit.isStoppedAddress(0x4016_9000));
    try std.testing.expect(!unit.isStoppedAddress(0x4008_0040)); // PORT2 never gated

    unit.write(mstp.win_base + mstp.ofs.b, 4, ~mstp.bit.sci9);
    try std.testing.expect(unit.sciActive(1));
    try std.testing.expect(!unit.isStoppedAddress(0x4011_8900));
    try std.testing.expect(unit.isStoppedAddress(0x4011_8000));
}
