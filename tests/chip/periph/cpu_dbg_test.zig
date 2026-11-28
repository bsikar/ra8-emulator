//! Tests for src/chip/periph/cpu_dbg.zig.
const std = @import("std");
const ra8 = @import("ra8");

const cpu_dbg = ra8.chip.periph.cpu_dbg;

fn at(offset: u32) u32 {
    return cpu_dbg.win_base + offset;
}

test "CPU_DBG starts with debug ports open, AL2 auth, and quiet status" {
    const unit = cpu_dbg.Unit{};
    try std.testing.expect(unit.quiet());
    try std.testing.expectEqual(@as(u32, 0), unit.read(at(cpu_dbg.regs.dbgstr), 4));
    try std.testing.expectEqual(cpu_dbg.dbgauth0_bits.all_enables, unit.read(at(cpu_dbg.regs.dbgauth0), 4));
    try std.testing.expectEqual(cpu_dbg.alctrl_bits.al2, unit.read(at(cpu_dbg.regs.alctrl), 4));
}

test "clearing DBGAUTH0 locks debug enables and raises SWDBG bit 31" {
    var unit = cpu_dbg.Unit{};
    unit.write(at(cpu_dbg.regs.dbgauth0), 4, 0);
    const val = unit.read(at(cpu_dbg.regs.dbgauth0), 4);
    try std.testing.expectEqual(@as(u32, 0), val & cpu_dbg.dbgauth0_bits.all_enables);
    try std.testing.expect((val & cpu_dbg.dbgauth0_bits.swdbg) != 0);
    try std.testing.expectEqual(@as(u32, 1), unit.lockdown_writes);
    try std.testing.expect(!unit.quiet());
}

test "ALCTRL accepts authentication level and fail count bits while DBGSTR stays RO" {
    var unit = cpu_dbg.Unit{ .dbgstr = cpu_dbg.dbgstr_bits.cdbgpwrupreq | cpu_dbg.dbgstr_bits.cdbgpwrupack };
    unit.write(at(cpu_dbg.regs.dbgstr), 4, 0);
    try std.testing.expectEqual(
        cpu_dbg.dbgstr_bits.cdbgpwrupreq | cpu_dbg.dbgstr_bits.cdbgpwrupack,
        unit.read(at(cpu_dbg.regs.dbgstr), 4),
    );
    unit.write(at(cpu_dbg.regs.alctrl), 4, cpu_dbg.alctrl_bits.al0 | (2 << 30) | 0x00FF_0000);
    try std.testing.expectEqual(cpu_dbg.alctrl_bits.al0 | (2 << 30), unit.read(at(cpu_dbg.regs.alctrl), 4));
    unit.write(at(cpu_dbg.regs.dbgstopcr), 4, 0x0000_0003);
    try std.testing.expectEqual(@as(u32, 0x0000_0003), unit.read(at(cpu_dbg.regs.dbgstopcr), 4));
}
