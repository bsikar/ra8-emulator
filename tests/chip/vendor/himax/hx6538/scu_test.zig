//! Covers src/chip/vendor/himax/hx6538/scu.zig: CM55S hold/release, VTORs, IDAU, and clocks.
const ra8 = @import("ra8");
const std = @import("std");

const scu = ra8.chip.vendor.himax.hx6538.scu;

test "SCU defaults keep CM55S held in reset/CPUWAIT until both gates release" {
    var unit: scu.Scu = .{};
    try std.testing.expectEqual(@as(u32, 0), unit.readAon(scu.aon_regs.cm55s_state));
    try std.testing.expectEqual(@as(u32, 1), unit.readAon(scu.aon_regs.cm55s_cpuwait));
    try std.testing.expectEqual(@as(u32, 1), unit.readAon(scu.aon_regs.cm55m_state));
    try std.testing.expectEqual(@as(u32, 0), unit.readAon(scu.aon_regs.cm55m_cpuwait));
    try std.testing.expect(!unit.cm55sRunning());

    unit.writeAon(scu.aon_regs.cm55s_initsvtor, 0x3401_0000);
    unit.writeAon(scu.aon_regs.cm55s_state, 1);
    try std.testing.expect(!unit.cm55sRunning()); // CPUWAIT still asserted
    unit.writeAon(scu.aon_regs.cm55s_cpuwait, 0);
    try std.testing.expect(unit.cm55sRunning());
    try std.testing.expectEqual(@as(u32, 0x3401_0000), unit.readAon(scu.aon_regs.cm55s_initsvtor));
}

test "SCU_SB timer clock control and SCU_LSC CM55S reset mask retain written fields" {
    var unit: scu.Scu = .{};
    unit.writeSb(scu.sb_regs.timer_clk_en_ctrl, 0x0000_01FF);
    try std.testing.expectEqual(@as(u32, 0x0000_01FF), unit.readSb(scu.sb_regs.timer_clk_en_ctrl));
    unit.writeLsc(scu.lsc_regs.cm55s_reset_mask, 1);
    try std.testing.expectEqual(@as(u32, 1), unit.readLsc(scu.lsc_regs.cm55s_reset_mask));
}
