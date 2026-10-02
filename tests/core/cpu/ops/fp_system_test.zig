//! Covers src/core/cpu/ops/fp_system.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.core.cpu.cpu.Cpu;
const Instr = ra8.core.cpu.instr.Instr;
const fp_system = ra8.core.cpu.ops.fp_system;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = fp_system.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

fn fresh() Cpu {
    return .{ .bus = undefined };
}

fn nzcv(cpu: *const Cpu) u4 {
    return @intCast(cpu.fp.fpscr.bits() >> 28);
}

test "vcmp.f32 s0, s1: 1.0 < 2.0 sets N" {
    var cpu = fresh();
    cpu.fp.bank.writeS(0, 0x3F80_0000);
    cpu.fp.bank.writeS(1, 0x4000_0000);
    try run(&cpu, 0xEEB4, 0x0A60);
    try std.testing.expectEqual(@as(u4, 0b1000), nzcv(&cpu));
}

test "vcmp on a quiet NaN is unordered and quiet; vcmpe signals IOC" {
    var cpu = fresh();
    cpu.fp.bank.writeD(1, 0x7FF8_0000_0000_0000);
    try run(&cpu, 0xEEB4, 0x0B41);
    try std.testing.expectEqual(@as(u4, 0b0011), nzcv(&cpu));
    try std.testing.expectEqual(@as(u1, 0), cpu.fp.fpscr.ioc);
    try run(&cpu, 0xEEB4, 0x0BC1);
    try std.testing.expectEqual(@as(u1, 1), cpu.fp.fpscr.ioc);
}

test "vcmp.f32 s2, #0.0 treats -0.0 as equal; positive is greater" {
    var cpu = fresh();
    cpu.fp.bank.writeS(2, 0x8000_0000);
    try run(&cpu, 0xEEB5, 0x1A40);
    try std.testing.expectEqual(@as(u4, 0b0110), nzcv(&cpu));
    cpu.fp.bank.writeS(2, 0x3F80_0000);
    try run(&cpu, 0xEEB5, 0x1A40);
    try std.testing.expectEqual(@as(u4, 0b0010), nzcv(&cpu));
}

test "vmrs APSR_nzcv, FPSCR copies only the flags" {
    var cpu = fresh();
    cpu.regs.xpsr = 0x0100_0000;
    fp_system.setNzcv(&cpu.fp.fpscr, 0b1010);
    cpu.fp.fpscr.ioc = 1;
    try run(&cpu, 0xEEF1, 0xFA10);
    try std.testing.expectEqual(@as(u32, 0xA100_0000), cpu.regs.xpsr);
}

test "vmrs r3, FPSCR and vmsr FPSCR, r2 masks reserved bits" {
    var cpu = fresh();
    cpu.regs.set(2, 0xFFFF_FFFF);
    try run(&cpu, 0xEEE1, 0x2A10);
    try std.testing.expectEqual(@as(u32, 0xFFCF_009F), cpu.fp.fpscr.bits());
    try run(&cpu, 0xEEF1, 0x3A10);
    try std.testing.expectEqual(@as(u32, 0xFFCF_009F), cpu.regs.get(3));
}

test "unclaimed: SBZ bits, D16+, SP or PC, other system registers, arith space" {
    try std.testing.expect(fp_system.group.decode(wide(0xEEB5, 0x1A60)) == null);
    try std.testing.expect(fp_system.group.decode(wide(0xEEB5, 0x1A41)) == null);
    try std.testing.expect(fp_system.group.decode(wide(0xEEF4, 0x0B40)) == null);
    try std.testing.expect(fp_system.group.decode(wide(0xEEB4, 0x0B61)) == null);
    try std.testing.expect(fp_system.group.decode(wide(0xEEF1, 0xDA10)) == null);
    try std.testing.expect(fp_system.group.decode(wide(0xEEE1, 0xFA10)) == null);
    try std.testing.expect(fp_system.group.decode(wide(0xEEF2, 0x3A10)) == null);
    try std.testing.expect(fp_system.group.decode(wide(0xEEF1, 0x3A30)) == null);
    try std.testing.expect(fp_system.group.decode(wide(0xEE30, 0x0A81)) == null);
}
