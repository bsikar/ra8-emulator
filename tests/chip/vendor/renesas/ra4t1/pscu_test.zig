//! Unit tests for RA4T1 `PSCU` and 8-region hardware IDAU attribution.
const ra8 = @import("ra8");
const std = @import("std");

const pscu = ra8.chip.vendor.renesas.ra4t1.pscu;
const sysc = ra8.chip.vendor.renesas.ra4t1.sysc;

test "PSCU reset assigns all flash and SRAM Secure and peripherals Non-secure" {
    const unit = pscu.Pscu.init(null);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), unit.read(pscu.win_base + pscu.ofs.psarb, 4));
    try std.testing.expectEqual(pscu.reset_val.cfsamona, unit.read(pscu.win_base + pscu.ofs.cfsamona, 4));
    try std.testing.expectEqual(pscu.reset_val.ssamona, unit.read(pscu.win_base + pscu.ofs.ssamona, 4));

    const cb = pscu.Pscu.resetCallback();
    const cf = cb.answer(0x0000_1000);
    try std.testing.expectEqual(ra8.chip.periph.sau.attribution.State.secure, cf.state);
    try std.testing.expectEqual(@as(?u8, 0x07), cf.region);

    const df = cb.answer(0x0800_0400);
    try std.testing.expectEqual(ra8.chip.periph.sau.attribution.State.secure, df.state);
    try std.testing.expectEqual(@as(?u8, 0x0B), df.region);

    const sram = cb.answer(0x2000_4000);
    try std.testing.expectEqual(ra8.chip.periph.sau.attribution.State.secure, sram.state);
    try std.testing.expectEqual(@as(?u8, 0x0F), sram.region);

    const mmio = cb.answer(0x4011_8900);
    try std.testing.expect(mmio.exempt);
    try std.testing.expectEqual(@as(?u8, null), mmio.region);
}

test "PSCU splits all 8 IDAU regions when unlocked via PRCR.PRC4" {
    var guard = sysc.Sysc.init();
    var unit = pscu.Pscu.init(&guard);

    // Locked without PRC4.
    unit.write(pscu.win_base + pscu.ofs.cfsamonb, 4, 32 << 10);
    try std.testing.expectEqual(pscu.reset_val.cfsamonb, unit.cfsamonb);
    try std.testing.expectEqual(@as(u32, 1), unit.ignored_protected);

    guard.write(sysc.win_base + sysc.ofs.prcr, 2, 0xA510);
    // Code flash: 32 KB S, 32 KB NSC (total 64 KB), rest NS.
    unit.write(pscu.win_base + pscu.ofs.cfsamonb, 4, 32 << 10);
    unit.write(pscu.win_base + pscu.ofs.cfsamona, 4, 2 << 15);
    // Data flash: 2 KB S, 2 KB NS.
    unit.write(pscu.win_base + pscu.ofs.dfsamon, 4, 2 << 10);
    // SRAM0: 8 KB S, 8 KB NSC (total 16 KB), rest NS.
    unit.write(pscu.win_base + pscu.ofs.ssamonb, 4, 8 << 10);
    unit.write(pscu.win_base + pscu.ofs.ssamona, 4, 2 << 13);

    const cb = unit.callback();
    try std.testing.expectEqual(@as(?u8, 0x07), cb.answer(0x0000_7FFC).region);
    try std.testing.expectEqual(@as(?u8, 0x06), cb.answer(0x0000_8000).region);
    try std.testing.expectEqual(ra8.chip.periph.sau.attribution.State.callable, cb.answer(0x0000_8000).state);
    try std.testing.expectEqual(@as(?u8, 0x05), cb.answer(0x0001_0000).region);
    try std.testing.expectEqual(ra8.chip.periph.sau.attribution.State.non_secure, cb.answer(0x0001_0000).state);

    try std.testing.expectEqual(@as(?u8, 0x0B), cb.answer(0x0800_07FF).region);
    try std.testing.expectEqual(@as(?u8, 0x09), cb.answer(0x0800_0800).region);

    try std.testing.expectEqual(@as(?u8, 0x0F), cb.answer(0x2000_1FFF).region);
    try std.testing.expectEqual(@as(?u8, 0x0E), cb.answer(0x2000_2000).region);
    try std.testing.expectEqual(@as(?u8, 0x0D), cb.answer(0x2000_4000).region);
}
