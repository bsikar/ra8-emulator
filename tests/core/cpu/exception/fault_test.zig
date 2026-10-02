//! Covers src/core/cpu/exception/fault.zig through Cpu.step.
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("ram.zig");
const memmap = ra8.core.memmap;

const usage_handler: u32 = fixture.base + 0x1C0;
const hard_handler: u32 = fixture.base + 0x1E0;
const usgfaultena: u32 = 1 << 18;
const unaligned_bit: u32 = 1 << 24;
const invstate_bit: u32 = 1 << 17;
const forced: u32 = 1 << 30;

/// `ldm r0!, {r1, r2}` at the reset PC with r0 one byte off a word.
fn faulting(ram: *fixture.Ram) !ra8.core.cpu.cpu.Cpu {
    ram.putWord(fixture.base + 3 * 4, hard_handler | 1);
    ram.putWord(fixture.base + 6 * 4, usage_handler | 1);
    ram.putWord(fixture.code, 0x0000_C806);
    var cpu = try fixture.boot(ram);
    cpu.regs.low[0] = fixture.base + 0x201;
    return cpu;
}

fn ipsr(cpu: *const ra8.core.cpu.cpu.Cpu) u32 {
    return cpu.regs.xpsr & 0x1FF;
}

test "an unaligned access is taken as UsageFault when USGFAULTENA is set" {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, usgfaultena);
    var cpu = try faulting(&ram);
    try std.testing.expectEqual(@as(?ra8.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(usage_handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 6), ipsr(&cpu));
    try std.testing.expectEqual(unaligned_bit, ram.word(memmap.scb.cfsr));
    try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.hfsr));
    // The faulting instruction is the stacked return address.
    try std.testing.expectEqual(fixture.code, ram.word(cpu.regs.sp() + 24));
    try std.testing.expectEqual(fixture.base + 0x201, cpu.regs.low[0]);
}

test "with USGFAULTENA clear it escalates to HardFault and sets HFSR.FORCED" {
    var ram: fixture.Ram = .{};
    var cpu = try faulting(&ram);
    try std.testing.expectEqual(@as(?ra8.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(hard_handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 3), ipsr(&cpu));
    try std.testing.expectEqual(unaligned_bit, ram.word(memmap.scb.cfsr));
    try std.testing.expectEqual(forced, ram.word(memmap.scb.hfsr));
}

test "EPSR.T clear raises INVSTATE" {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, usgfaultena);
    var cpu = try faulting(&ram);
    cpu.regs.xpsr &= ~ra8.core.cpu.regs.xpsr_bits.thumb;
    try std.testing.expectEqual(@as(?ra8.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(usage_handler, cpu.regs.pc);
    try std.testing.expectEqual(invstate_bit, ram.word(memmap.scb.cfsr));
}

test "a fault with FAULTMASK set locks up and stops instead" {
    var ram: fixture.Ram = .{};
    var cpu = try faulting(&ram);
    cpu.regs.faultmask = 1;
    try std.testing.expectEqual(fixture.code, cpu.step().?.unaligned);
    try std.testing.expectEqual(fixture.code, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.cfsr));
}

test "a fault inside HardFault locks up" {
    var ram: fixture.Ram = .{};
    var cpu = try faulting(&ram);
    try std.testing.expectEqual(@as(?ra8.core.cpu.cpu.Stop, null), cpu.step());
    ram.putWord(hard_handler, 0x0000_C806);
    try std.testing.expectEqual(hard_handler, cpu.step().?.unaligned);
}
