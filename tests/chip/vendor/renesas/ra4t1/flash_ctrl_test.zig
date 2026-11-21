//! Unit tests for RA4T1 `FACI` (`0x407E_0000` / `0x407F_E000`) and `SRAM` control (`0x4000_2000`).
const ra8 = @import("ra8");
const std = @import("std");

const fc = ra8.chip.vendor.renesas.ra4t1.flash_ctrl;

test "FACI reports ready and SRAMWTSC requires SRAMPRCR2 key 0x78" {
    var unit = fc.FlashCtrl.init();
    const regs = unit.regBlock();
    const cmd = unit.cmdBlock();
    const sram = unit.sramBlock();

    const got_fstatr = regs.readFn(regs.context, fc.faci_reg_base + fc.faci_ofs.fstatr, 4);
    try std.testing.expectEqual(@as(u32, 0x0000_8000), got_fstatr);
    cmd.writeFn(cmd.context, fc.faci_cmd_base, 1, 0xE8);
    try std.testing.expectEqual(@as(u32, 1), unit.commands);

    try std.testing.expectEqual(@as(u32, 1), sram.readFn(sram.context, fc.sram_base + fc.sram_ofs.sramwtsc, 1));
    sram.writeFn(sram.context, fc.sram_base + fc.sram_ofs.sramwtsc, 1, 0);
    try std.testing.expectEqual(@as(u32, 1), sram.readFn(sram.context, fc.sram_base + fc.sram_ofs.sramwtsc, 1));

    sram.writeFn(sram.context, fc.sram_base + fc.sram_ofs.sramprcr2, 1, (0x78 << 1) | 1);
    sram.writeFn(sram.context, fc.sram_base + fc.sram_ofs.sramwtsc, 1, 0);
    try std.testing.expectEqual(@as(u32, 0), sram.readFn(sram.context, fc.sram_base + fc.sram_ofs.sramwtsc, 1));
}
