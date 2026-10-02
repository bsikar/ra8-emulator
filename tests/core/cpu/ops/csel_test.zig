//! Covers src/core/cpu/ops/csel.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.core.cpu.cpu.Cpu;
const csel = ra8.core.cpu.ops.csel;

const z_flag: u32 = 1 << 30;

fn wide(hw1: u16, hw2: u16) ra8.core.cpu.instr.Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

/// Runs the op with r2 = 7, r3 = 40 and the given xPSR; returns r1.
fn run(hw1: u16, hw2: u16, xpsr: u32) !u32 {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[1] = 0xDEAD_BEEF;
    cpu.regs.low[2] = 7;
    cpu.regs.low[3] = 40;
    cpu.regs.xpsr = xpsr;
    const exec = csel.group.decode(wide(hw1, hw2)) orelse return error.NotClaimed;
    try exec(&cpu, wide(hw1, hw2));
    try std.testing.expectEqual(xpsr, cpu.regs.xpsr);
    return cpu.regs.low[1];
}

test "cset r1, eq (csinc r1, zr, zr, ne) from usb_port_init" {
    try std.testing.expectEqual(@as(u32, 1), try run(0xEA5F, 0x911F, z_flag));
    try std.testing.expectEqual(@as(u32, 0), try run(0xEA5F, 0x911F, 0));
}

test "csel r1, r2, r3, eq picks Rn on pass and Rm on fail" {
    try std.testing.expectEqual(@as(u32, 7), try run(0xEA52, 0x8103, z_flag));
    try std.testing.expectEqual(@as(u32, 40), try run(0xEA52, 0x8103, 0));
}

test "csinv and csneg tails on fail" {
    try std.testing.expectEqual(~@as(u32, 40), try run(0xEA52, 0xA103, 0));
    try std.testing.expectEqual(@as(u32, 0) -% 40, try run(0xEA52, 0xB103, 0));
}

test "sp fields, rd = zr, AL and other kinds stay unclaimed" {
    try std.testing.expect(csel.group.decode(wide(0xEA5D, 0x8103)) == null); // Rn = SP
    try std.testing.expect(csel.group.decode(wide(0xEA52, 0x810D)) == null); // Rm = SP
    try std.testing.expect(csel.group.decode(wide(0xEA52, 0x8D03)) == null); // Rd = SP
    try std.testing.expect(csel.group.decode(wide(0xEA52, 0x8F03)) == null); // Rd = ZR
    try std.testing.expect(csel.group.decode(wide(0xEA52, 0x81E3)) == null); // AL
    try std.testing.expect(csel.group.decode(wide(0xEA52, 0x0103)) == null); // not CSEL
}
