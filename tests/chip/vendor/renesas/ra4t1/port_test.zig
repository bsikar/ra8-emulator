//! Unit tests for RA4T1 `PORT0..5, 8` and `PFS`/`PWPR`/`PmSAR`.
const ra8 = @import("ra8");
const std = @import("std");

const port = ra8.chip.vendor.renesas.ra4t1.port;

test "PORT2 PIDR returns 0x01C3 when P207 is driven high" {
    var unit = port.Port.init(null);
    const port2 = port.port_base + 0x40;
    try std.testing.expectEqual(@as(u32, 0x0143), unit.readPort(port2 + port.reg_ofs.pcntr2, 4));

    unit.writePort(port2 + port.reg_ofs.pcntr1, 4, (@as(u32, 1 << 7) << 16) | (1 << 7));
    try std.testing.expectEqual(@as(u32, 0x01C3), unit.readPort(port2 + port.reg_ofs.pcntr2, 4) & 0xFFFF);

    unit.writePort(port2 + port.reg_ofs.pcntr3, 4, @as(u32, 1 << 7) << 16);
    try std.testing.expectEqual(@as(u32, 0x0143), unit.readPort(port2 + port.reg_ofs.pcntr2, 4) & 0xFFFF);
}

test "PmnPFS reset values and PWPR two-step unlock match RA4T1 HUM" {
    var unit = port.Port.init(null);
    try std.testing.expectEqual(@as(u32, 0x0000_8000), unit.readPfs(port.pfs_base, 4)); // P000
    // P108, P201, P300 have pull-ups enabled (PCR=1) so live PIDR bit 1 reads high.
    try std.testing.expectEqual(@as(u32, 0x0001_0412), unit.readPfs(port.pfs_base + 0x40 + 8 * 4, 4)); // P108
    try std.testing.expectEqual(@as(u32, 0x0000_0012), unit.readPfs(port.pfs_base + 0x80 + 1 * 4, 4)); // P201
    try std.testing.expectEqual(@as(u32, 0x0001_0012), unit.readPfs(port.pfs_base + 0xC0, 4)); // P300

    const p109 = port.pfs_base + 0x40 + 9 * 4;
    // Direct PFSWE write while B0WI=1 is refused.
    unit.writePfs(port.pfs_base + port.reg_ofs.pwpr, 1, 0x40);
    unit.writePfs(p109, 4, 0x0501_0405);
    try std.testing.expectEqual(@as(u32, 0), unit.readPfs(p109, 4));
    try std.testing.expectEqual(@as(u32, 1), unit.pfs_blocked);

    // Two-step unlock succeeds.
    unit.writePfs(port.pfs_base + port.reg_ofs.pwpr, 1, 0x00);
    unit.writePfs(port.pfs_base + port.reg_ofs.pwpr, 1, 0x40);
    unit.writePfs(p109, 4, 0x0501_0405);
    // Live PIDR (bit 1) reflects PODR=1 when PDR=1 -> 0x0501_0407.
    try std.testing.expectEqual(@as(u32, 0x0501_0407), unit.readPfs(p109, 4));
}
