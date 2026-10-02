//! Tests for src/core/banked.zig: the Secure/Non-secure register banks.
const std = @import("std");
const ra8 = @import("ra8");
const banked = ra8.core.banked;
const Regs = ra8.core.cpu.regs.Regs;

test "a state switch swaps the banked registers and keeps the shared ones" {
    var r = Regs{ .msp = 0x2000_1000, .psp = 0x2000_2000, .primask = 1, .basepri = 0x40, .control = 0b1110, .lr = 0xFFFF_FFF9 };
    r.low[0] = 7;
    var b = banked.Banked{ .msplim = 0x2000_0800 };
    b.other = .{ .msp = 0x3000_1000, .psp = 0x3000_2000, .msplim = 0x3000_0000, .control = 0b01 };
    b.switchTo(&r, .non_secure);
    try std.testing.expectEqual(banked.State.non_secure, b.current);
    try std.testing.expectEqual(@as(u32, 0x3000_1000), r.msp);
    try std.testing.expectEqual(@as(u32, 0x3000_2000), r.psp);
    try std.testing.expectEqual(@as(u32, 0x3000_0000), b.msplim);
    try std.testing.expectEqual(@as(u32, 0), r.primask);
    // nPRIV/SPSEL come from the Non-secure bank, FPCA/SFPA stay as they were.
    try std.testing.expectEqual(@as(u32, 0b1101), r.control);
    try std.testing.expectEqual(@as(u32, 7), r.low[0]);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFF9), r.lr);
    try std.testing.expectEqual(banked.Bank{ .msp = 0x2000_1000, .psp = 0x2000_2000, .msplim = 0x2000_0800, .primask = 1, .basepri = 0x40, .control = 0b10 }, b.other);
    b.switchTo(&r, .secure);
    try std.testing.expectEqual(@as(u32, 0x2000_1000), r.msp);
    try std.testing.expectEqual(@as(u32, 0b1110), r.control);
    try std.testing.expectEqual(@as(u32, 0x40), r.basepri);
}

test "switching to the running state changes nothing" {
    var r = Regs{ .msp = 0x10 };
    var b = banked.Banked{};
    b.other.msp = 0x20;
    b.switchTo(&r, .secure);
    try std.testing.expectEqual(@as(u32, 0x10), r.msp);
    try std.testing.expectEqual(@as(u32, 0x20), b.other.msp);
}

test "bank reads either state's copy wherever it lives" {
    var r = Regs{ .msp = 0x10 };
    var b = banked.Banked{};
    b.other.msp = 0x20;
    try std.testing.expectEqual(@as(u32, 0x10), b.bank(&r, .secure).msp);
    try std.testing.expectEqual(@as(u32, 0x20), b.bank(&r, .non_secure).msp);
    b.switchTo(&r, .non_secure);
    try std.testing.expectEqual(@as(u32, 0x10), b.bank(&r, .secure).msp);
    try std.testing.expectEqual(@as(u32, 0x20), b.bank(&r, .non_secure).msp);
}

test "Secure code reaches the Non-secure copy through the _NS encodings" {
    const s = banked.sysm;
    var r = Regs{};
    var b = banked.Banked{};
    try std.testing.expect(b.writeNs(&r, s.msp_ns, 0x3000_1003));
    try std.testing.expect(b.writeNs(&r, s.psp_ns, 0x3000_2002));
    try std.testing.expect(b.writeNs(&r, s.msplim_ns, 0x3000_0007));
    try std.testing.expect(b.writeNs(&r, s.psplim_ns, 0x3000_0105));
    try std.testing.expect(b.writeNs(&r, s.primask_ns, 3));
    try std.testing.expect(b.writeNs(&r, s.basepri_ns, 0x1E0));
    try std.testing.expect(b.writeNs(&r, s.faultmask_ns, 2));
    try std.testing.expect(b.writeNs(&r, s.control_ns, 0xF));
    try std.testing.expectEqual(@as(?u32, 0x3000_1000), b.readNs(&r, s.msp_ns));
    try std.testing.expectEqual(@as(?u32, 0x3000_2000), b.readNs(&r, s.psp_ns));
    try std.testing.expectEqual(@as(?u32, 0x3000_0000), b.readNs(&r, s.msplim_ns));
    try std.testing.expectEqual(@as(?u32, 0x3000_0100), b.readNs(&r, s.psplim_ns));
    try std.testing.expectEqual(@as(?u32, 1), b.readNs(&r, s.primask_ns));
    try std.testing.expectEqual(@as(?u32, 0xE0), b.readNs(&r, s.basepri_ns));
    try std.testing.expectEqual(@as(?u32, 0), b.readNs(&r, s.faultmask_ns));
    try std.testing.expectEqual(@as(?u32, 0b11), b.readNs(&r, s.control_ns));
    // The running (Secure) copy is untouched.
    try std.testing.expectEqual(@as(u32, 0), r.msp);
    try std.testing.expectEqual(@as(u32, 0), r.control);
}

test "SP_NS follows the Non-secure SPSEL and the shared mode" {
    const s = banked.sysm;
    var r = Regs{};
    var b = banked.Banked{};
    b.other = .{ .msp = 0x100, .psp = 0x200, .control = banked.control_banked };
    try std.testing.expectEqual(@as(?u32, 0x200), b.readNs(&r, s.sp_ns));
    try std.testing.expect(b.writeNs(&r, s.sp_ns, 0x204));
    try std.testing.expectEqual(@as(u32, 0x204), b.other.psp);
    r.xpsr = 3; // Handler mode always uses the Main stack.
    try std.testing.expectEqual(@as(?u32, 0x100), b.readNs(&r, s.sp_ns));
}

test "the _NS encodings are not this file's from Non-secure state" {
    var r = Regs{};
    var b = banked.Banked{ .current = .non_secure };
    try std.testing.expectEqual(@as(?u32, null), b.readNs(&r, banked.sysm.msp_ns));
    try std.testing.expect(!b.writeNs(&r, banked.sysm.msp_ns, 4));
    var s = banked.Banked{};
    try std.testing.expectEqual(@as(?u32, null), s.readNs(&r, 0x08));
    try std.testing.expect(!s.writeNs(&r, 0x92, 0));
}
