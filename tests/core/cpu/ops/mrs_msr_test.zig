//! Covers src/core/cpu/ops/mrs_msr.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.core.cpu.cpu.Cpu;
const Instr = ra8.core.cpu.instr.Instr;
const regs = ra8.core.cpu.regs;
const mrs_msr = ra8.core.cpu.ops.mrs_msr;
const branch_wide = ra8.core.cpu.ops.branch_wide;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const exec = mrs_msr.group.decode(wide(hw1, hw2)) orelse return error.NotClaimed;
    try exec(cpu, wide(hw1, hw2));
}

fn fresh() Cpu {
    return .{ .bus = undefined, .regs = .{ .xpsr = regs.xpsr_bits.thumb } };
}

test "mrs r0, ipsr is the blink_hal encoding" {
    var cpu = fresh();
    cpu.regs.xpsr |= 0x2F;
    cpu.regs.low[0] = 0xDEAD;
    try run(&cpu, 0xF3EF, 0x8005);
    try std.testing.expectEqual(@as(u32, 0x2F), cpu.regs.low[0]);
}

test "msr primask, r1 then mrs r2, primask round-trips" {
    var cpu = fresh();
    cpu.regs.low[1] = 1;
    try run(&cpu, 0xF381, 0x8810);
    try std.testing.expectEqual(@as(u32, 1), cpu.regs.primask);
    try run(&cpu, 0xF3EF, 0x8210);
    try std.testing.expectEqual(@as(u32, 1), cpu.regs.low[2]);
}

test "msr apsr_nzcvq and apsr_g write their own bits" {
    var cpu = fresh();
    cpu.regs.low[3] = 0xFFFF_FFFF;
    try run(&cpu, 0xF383, 0x8800); // msr apsr_nzcvq, r3
    try std.testing.expectEqual(0xF800_0000 | regs.xpsr_bits.thumb, cpu.regs.xpsr);
    try run(&cpu, 0xF383, 0x8400); // msr apsr_g, r3
    try std.testing.expectEqual(@as(u32, 0x000F_0000), cpu.regs.xpsr & 0x000F_0000);
}

test "unclaimed: SP or PC operands, mask 00, a non-10 mask off xPSR, MSPLIM" {
    try std.testing.expect(mrs_msr.group.decode(wide(0xF3EF, 0x8D05)) == null);
    try std.testing.expect(mrs_msr.group.decode(wide(0xF38D, 0x8810)) == null);
    try std.testing.expect(mrs_msr.group.decode(wide(0xF381, 0x8010)) == null);
    try std.testing.expect(mrs_msr.group.decode(wide(0xF381, 0x8C10)) == null);
    try std.testing.expect(mrs_msr.group.decode(wide(0xF3EF, 0x800A)) == null);
}

test "branch_wide does not claim these encodings first" {
    try std.testing.expect(branch_wide.group.decode(wide(0xF3EF, 0x8005)) == null);
    try std.testing.expect(branch_wide.group.decode(wide(0xF381, 0x8810)) == null);
}
