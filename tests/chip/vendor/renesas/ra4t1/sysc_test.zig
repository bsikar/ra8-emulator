//! Unit tests for RA4T1 `SYSC` clocks and `PRCR`/`PRCRN` write protection.
const ra8 = @import("ra8");
const std = @import("std");

const sysc = ra8.chip.vendor.renesas.ra4t1.sysc;

test "SYSC reset clocks and register defaults match RA4T1 HUM" {
    const unit = sysc.Sysc.init();
    try std.testing.expectEqual(@as(u32, 0x2200_2222), unit.read(sysc.win_base + sysc.ofs.sckdivcr, 4));
    try std.testing.expectEqual(@as(u32, 0x01), unit.read(sysc.win_base + sysc.ofs.sckscr, 1));
    try std.testing.expectEqual(@as(u32, 0x01), unit.read(sysc.win_base + sysc.ofs.hococr, 1));
    try std.testing.expectEqual(@as(u32, 0x03), unit.read(sysc.win_base + sysc.ofs.hococr2, 1));
    try std.testing.expectEqual(@as(u32, 0x00), unit.read(sysc.win_base + sysc.ofs.oscsf, 1));
    try std.testing.expectEqual(@as(u32, 0x0000), unit.read(sysc.win_base + sysc.ofs.prcr, 2));
    try std.testing.expectEqual(@as(u32, 2_000_000), unit.iclkHz());
}

test "PRCR key and PRCRN PRC4 isolation control clock updates" {
    var unit = sysc.Sysc.init();
    unit.write(sysc.win_base + sysc.ofs.hococr2, 1, 0x02);
    try std.testing.expectEqual(@as(u8, 0x03), unit.hococr2);
    try std.testing.expectEqual(@as(u32, 1), unit.ignored_protected);

    // Wrong key is ignored.
    unit.write(sysc.win_base + sysc.ofs.prcr, 2, 0x5A03);
    try std.testing.expectEqual(@as(u16, 0), unit.prcr);
    try std.testing.expectEqual(@as(u32, 1), unit.bad_keys);

    // PRCRN cannot unlock PRC4 (security).
    unit.write(sysc.win_base + sysc.ofs.prcrn, 2, 0xA51F);
    try std.testing.expect(!unit.allows(sysc.prc.security));
    try std.testing.expect(unit.allows(sysc.prc.clock));
}

test "HOCO 20 MHz sequence requires clearing prohibited HOCOCR2=3 while stopped" {
    var unit = sysc.Sysc.init();
    unit.write(sysc.win_base + sysc.ofs.prcr, 2, 0xA503);

    // Starting HOCO while HOCOCR2==0x03 leaves OSCSF.HOCOSF clear.
    unit.write(sysc.win_base + sysc.ofs.hococr, 1, 0x00);
    try std.testing.expectEqual(@as(u32, 0), unit.read(sysc.win_base + sysc.ofs.oscsf, 1));

    // Attempt to write HOCOCR2 while HOCO is running is ignored.
    unit.write(sysc.win_base + sysc.ofs.hococr2, 1, 0x02);
    try std.testing.expectEqual(@as(u8, 0x03), unit.hococr2);

    // Stop HOCO, set 20 MHz, restart, switch SCKSCR & SCKDIVCR to /1.
    unit.write(sysc.win_base + sysc.ofs.hococr, 1, 0x01);
    unit.write(sysc.win_base + sysc.ofs.hococr2, 1, 0x02);
    unit.write(sysc.win_base + sysc.ofs.hococr, 1, 0x00);
    try std.testing.expectEqual(@as(u32, 1), unit.read(sysc.win_base + sysc.ofs.oscsf, 1));

    unit.write(sysc.win_base + sysc.ofs.sckdivcr, 4, 0);
    unit.write(sysc.win_base + sysc.ofs.sckscr, 1, 0);
    try std.testing.expectEqual(@as(u32, 0), unit.read(sysc.win_base + sysc.ofs.sckscr, 1));
    try std.testing.expectEqual(@as(u32, 20_000_000), unit.iclkHz());
}

test "PLL multiplier decodes full 6-bit PLLMUL range above 16x" {
    var unit = sysc.Sysc.init();
    unit.write(sysc.win_base + sysc.ofs.prcr, 2, 0xA503);
    unit.write(sysc.win_base + sysc.ofs.hococr2, 1, 0x00); // 16 MHz HOCO
    unit.write(sysc.win_base + sysc.ofs.hococr, 1, 0x00);
    // HOCO source (bit 4), PLIDIV=/4 (0x03), PLLMUL=0x31 -> (49 + 1) / 2 = 25.0x -> 100 MHz ICLK.
    unit.write(sysc.win_base + sysc.ofs.pllccr, 2, (@as(u16, 0x31) << 8) | (1 << 4) | 0x03);
    unit.write(sysc.win_base + sysc.ofs.pllcr, 1, 0x00);
    unit.write(sysc.win_base + sysc.ofs.sckdivcr, 4, 0x0000_0000);
    unit.write(sysc.win_base + sysc.ofs.sckscr, 1, sysc.cksel.pll);
    try std.testing.expectEqual(@as(u32, 100_000_000), unit.iclkHz());
}
