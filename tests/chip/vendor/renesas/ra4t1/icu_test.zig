//! Unit tests for RA4T1 `ICU` (`0x4000_6000`, `IELSR0..95 = 0x4000_6300 + 4*n`).
const ra8 = @import("ra8");
const std = @import("std");

const icu = ra8.chip.vendor.renesas.ra4t1.icu;

test "ICU IELSR event linking sets IR, pends NVIC ISPR, and repends" {
    var unit = icu.Icu.init();
    var store = try ra8.chip.core.cpu.memory.store.Store.init(null);
    defer store.deinit();
    const guest = ra8.chip.core.cpu.memory.guest.Guest{ .store = &store };

    // Bind IELSR5 to SCI9 TXI (0x1B7).
    const ielsr5 = icu.win_base + icu.ofs.ielsr + 5 * 4;
    unit.write(ielsr5, 4, 0x1B7);
    try std.testing.expectEqual(@as(u32, 0x1B7), unit.read(ielsr5, 4));

    const src = unit.irqSource();
    try src.raise(&guest, 98, 0x1B7);
    try std.testing.expect((unit.read(ielsr5, 4) & icu.ielsr_field.ir) != 0);
    try std.testing.expect(src.asserted(5));

    const ispr0 = try guest.readWord(ra8.chip.core.memmap.nvic.ispr);
    try std.testing.expect((ispr0 & (1 << 5)) != 0);

    // Clear NVIC pending manually; repend re-asserts because IR stays latched.
    try guest.writeWord(ra8.chip.core.memmap.nvic.icpr, 1 << 5);
    try src.repend(&guest, 98);
    const ispr_after = try guest.readWord(ra8.chip.core.memmap.nvic.ispr);
    try std.testing.expect((ispr_after & (1 << 5)) != 0);

    // Writing 0 to IR clears the latch; writing 1 preserves IR.
    unit.write(ielsr5, 4, icu.ielsr_field.ir | 0x1B7);
    try std.testing.expect(src.asserted(5));
    unit.write(ielsr5, 4, 0x1B7);
    try std.testing.expect(!src.asserted(5));
}

test "ICU NMIER bits are write-once until clearLatches" {
    var unit = icu.Icu.init();
    unit.write(icu.win_base + icu.ofs.nmier, 2, 0x0080);
    unit.write(icu.win_base + icu.ofs.nmier, 2, 0x0000);
    try std.testing.expectEqual(@as(u32, 0x0080), unit.read(icu.win_base + icu.ofs.nmier, 2));
}
