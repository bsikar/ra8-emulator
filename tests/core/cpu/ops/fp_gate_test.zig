//! Covers src/core/cpu/ops/fp_gate.zig: ExecuteFPCheck() opening a new FP
//! context in front of a gated group, per the Arm ARM (DDI0553).
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.core.cpu.cpu.Cpu;
const Instr = ra8.core.cpu.instr.Instr;
const ops = ra8.core.cpu.ops;
const fpca: u32 = 1 << 2;

const gated = ops.fp_gate.gated(ops.fp_arith.group);

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = gated.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

fn fresh() Cpu {
    return .{ .bus = undefined };
}

test "the gated group keeps its name and claims the same encodings" {
    try std.testing.expectEqualStrings(ops.fp_arith.group.name, gated.name);
    try std.testing.expect(gated.decode(wide(0xEE30, 0x0A81)) != null);
    try std.testing.expect(gated.decode(wide(0xF000, 0xB800)) == null);
}

test "the first FP op sets FPCA and seeds FPSCR from FPDSCR before it runs" {
    var cpu = fresh();
    cpu.fp.context.writeFpdscr(0x00C0_0000); // RMode towards zero
    cpu.fp.fpscr = @bitCast(@as(u32, 0x8000_0010)); // N, IXC
    cpu.fp.bank.writeS(1, 0x3F80_0000); // 1.0
    cpu.fp.bank.writeS(2, 0x3380_0000); // 2^-24
    try run(&cpu, 0xEE30, 0x0A81); // vadd.f32 s0, s1, s2
    try std.testing.expectEqual(fpca, cpu.regs.control & fpca);
    // Rounded towards zero, so the sum stays 1.0 and only IXC is set.
    try std.testing.expectEqual(@as(u32, 0x3F80_0000), cpu.fp.bank.readS(0));
    try std.testing.expectEqual(@as(u32, 0x00C4_0010), cpu.fp.fpscr.bits());
}

test "with FPCA already set the FPSCR carries over" {
    var cpu = fresh();
    cpu.regs.control = fpca;
    cpu.fp.context.writeFpdscr(0x00C0_0000);
    cpu.fp.fpscr = @bitCast(@as(u32, 0x8004_0000));
    cpu.fp.bank.writeS(1, 0x3F80_0000);
    cpu.fp.bank.writeS(2, 0x3F80_0000);
    try run(&cpu, 0xEE30, 0x0A81);
    try std.testing.expectEqual(@as(u32, 0x4000_0000), cpu.fp.bank.readS(0));
    try std.testing.expectEqual(@as(u32, 0x8004_0000), cpu.fp.fpscr.bits());
}

test "ASPEN clear leaves CONTROL alone" {
    var cpu = fresh();
    cpu.fp.context.writeFpccr(0);
    try run(&cpu, 0xEE30, 0x0A81);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.control);
}

test "the decode table routes FP encodings through the gate" {
    var cpu = fresh();
    const hit = ra8.core.cpu.decode.decode(wide(0xEE30, 0x0A81)) orelse return error.NotClaimed;
    try hit.exec(&cpu, wide(0xEE30, 0x0A81));
    try std.testing.expectEqual(fpca, cpu.regs.control & fpca);
}

const fixture = @import("../exception/ram.zig");

test "a pending lazy preservation is written before the FP op runs" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    const at = fixture.msp_top - 0x48;
    cpu.fp.context.writeFpcar(at);
    cpu.fp.context.fpccr.lspact = 1;
    cpu.fp.bank.writeS(0, 0x1111_1111);
    cpu.fp.bank.writeS(1, 0x3F80_0000);
    cpu.fp.bank.writeS(2, 0x3F80_0000);
    cpu.fp.fpscr = @bitCast(@as(u32, 0x2004_0000));
    try run(&cpu, 0xEE30, 0x0A81); // vadd.f32 s0, s1, s2
    try std.testing.expectEqual(@as(u1, 0), cpu.fp.context.fpccr.lspact);
    // The old S0 and FPSCR went to the frame; the add then ran on fresh state.
    try std.testing.expectEqual(@as(u32, 0x1111_1111), ram.word(at));
    try std.testing.expectEqual(@as(u32, 0x2004_0000), ram.word(at + 0x40));
    try std.testing.expectEqual(@as(u32, 0x4000_0000), cpu.fp.bank.readS(0));
}

test "no lazy preservation pending leaves memory alone" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    const at = fixture.msp_top - 0x48;
    cpu.fp.context.writeFpcar(at);
    cpu.fp.bank.writeS(0, 0x1111_1111);
    try run(&cpu, 0xEE30, 0x0A81);
    try std.testing.expectEqual(@as(u32, 0), ram.word(at));
}
