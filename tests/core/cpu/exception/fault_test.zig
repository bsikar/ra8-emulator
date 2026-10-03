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
const stkof_bit: u32 = 1 << 20;
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

test "an unaligned MVE load sets CFSR.UNALIGNED on the Zig core" {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, usgfaultena);
    ram.putHalf(fixture.code, 0xECB1); // vldrw.u32 q7, [r1], #8
    ram.putHalf(fixture.code + 2, 0xFF02);
    ram.putWord(fixture.base + 6 * 4, usage_handler | 1);
    var cpu = try fixture.boot(&ram);
    cpu.regs.low[1] = fixture.base + 0x202;

    try std.testing.expectEqual(@as(?ra8.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(usage_handler, cpu.regs.pc);
    try std.testing.expectEqual(unaligned_bit, ram.word(memmap.scb.cfsr));
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

fn stackOverrun(ram: *fixture.Ram, psp: bool, first: u16, second: ?u16) !ra8.core.cpu.cpu.Cpu {
    ram.putWord(fixture.base + 6 * 4, usage_handler | 1);
    ram.putWord(memmap.scb.shcsr, usgfaultena);
    ram.putHalf(fixture.code, first);
    if (second) |hw2| ram.putHalf(fixture.code + 2, hw2);
    var cpu = try fixture.boot(ram);
    if (psp) {
        cpu.regs.control |= ra8.core.cpu.regs.control_bits.spsel;
        cpu.regs.psp = fixture.psp_top;
        cpu.regs.psplim = fixture.psp_top;
    } else {
        cpu.regs.msplim = fixture.msp_top;
    }
    cpu.regs.low[0] = if (psp) fixture.psp_top - 4 else fixture.msp_top - 4;
    try std.testing.expectEqual(@as(?ra8.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(usage_handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 6), ipsr(&cpu));
    try std.testing.expectEqual(stkof_bit, ram.word(memmap.scb.cfsr));
    const frame_sp = if (psp) cpu.regs.psp else cpu.regs.sp();
    try std.testing.expectEqual(fixture.code, ram.word(frame_sp + 24));
    return cpu;
}

test "PUSH crossing MSPLIM raises STKOF" {
    var ram: fixture.Ram = .{};
    _ = try stackOverrun(&ram, false, 0xB401, null); // push {r0}
}

test "PUSH crossing PSPLIM raises STKOF" {
    var ram: fixture.Ram = .{};
    _ = try stackOverrun(&ram, true, 0xB401, null); // push {r0}
}

test "MSR MSP crossing MSPLIM raises STKOF" {
    var ram: fixture.Ram = .{};
    _ = try stackOverrun(&ram, false, 0xF380, 0x8808); // msr msp, r0
}

test "MSR PSP crossing PSPLIM raises STKOF" {
    var ram: fixture.Ram = .{};
    _ = try stackOverrun(&ram, true, 0xF380, 0x8809); // msr psp, r0
}

test "SUB SP crossing MSPLIM raises STKOF" {
    var ram: fixture.Ram = .{};
    _ = try stackOverrun(&ram, false, 0xB082, null); // sub sp, #8
}

test "SUB SP crossing PSPLIM raises STKOF" {
    var ram: fixture.Ram = .{};
    _ = try stackOverrun(&ram, true, 0xB082, null); // sub sp, #8
}

test "PUSH that stays above MSPLIM retires normally" {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, usgfaultena);
    ram.putHalf(fixture.code, 0xB401); // push {r0}
    var cpu = try fixture.boot(&ram);
    cpu.regs.msplim = fixture.msp_top - 16;
    try std.testing.expectEqual(@as(?ra8.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(fixture.code + 2, cpu.regs.pc);
    try std.testing.expectEqual(fixture.msp_top - 4, cpu.regs.msp);
    try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.cfsr));
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

test "a blx through a null function pointer is taken as INVSTATE at address zero" {
    // RA8EMU-121: an old usb_selftest_cdc build left its GOT out of the .data
    // copy, so `blx r4` ran with r4 = 0 and landed with EPSR.T clear.
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, usgfaultena);
    ram.putWord(fixture.base + 6 * 4, usage_handler | 1);
    ram.putWord(fixture.code, 0x0000_47A0);
    var cpu = try fixture.boot(&ram);
    cpu.regs.low[4] = 0;
    try std.testing.expectEqual(@as(?ra8.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.pc);
    try std.testing.expectEqual((fixture.code + 2) | 1, cpu.regs.lr);
    try std.testing.expectEqual(@as(?ra8.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(usage_handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 6), ipsr(&cpu));
    try std.testing.expectEqual(invstate_bit, ram.word(memmap.scb.cfsr));
    // The stacked return address is the even target the branch landed on.
    try std.testing.expectEqual(@as(u32, 0), ram.word(cpu.regs.sp() + 24));
}
