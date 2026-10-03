//! Covers src/core/cpu/exception/entry.zig.
const std = @import("std");
const ra8 = @import("ra8");
const regs = ra8.core.cpu.regs;
const entry = ra8.core.cpu.exception.entry;
const fixture = @import("ram.zig");

test "entry from Thread mode on the MSP stacks the frame and runs the handler" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    cpu.regs.low[0] = 0xA0;
    cpu.regs.low[12] = 0xC0;
    cpu.regs.lr = 0x2000_0141;
    cpu.regs.xpsr |= 0x8000_0000 | (0x3 << 25) | (0x2 << 10); // N, plus IT state
    try entry.take(&cpu, 11, 0x2000_0102);
    const sp = fixture.msp_top - 0x20;
    try std.testing.expectEqual(sp, cpu.regs.msp);
    try std.testing.expectEqual(fixture.handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFF9), cpu.regs.lr);
    try std.testing.expectEqual(@as(u32, 11), cpu.regs.xpsr & regs.xpsr_bits.ipsr);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.xpsr & entry.it_bits);
    try std.testing.expect(cpu.regs.xpsr & regs.xpsr_bits.thumb != 0);
    try std.testing.expect(cpu.regs.xpsr & 0x8000_0000 != 0);
    try std.testing.expectEqual(@as(u32, 0xA0), ram.word(sp));
    try std.testing.expectEqual(@as(u32, 0xC0), ram.word(sp + 16));
    try std.testing.expectEqual(@as(u32, 0x2000_0141), ram.word(sp + 20));
    try std.testing.expectEqual(@as(u32, 0x2000_0102), ram.word(sp + 24));
    try std.testing.expect(ram.word(sp + 28) & entry.it_bits != 0);
}

test "entry from Thread mode on the PSP stacks there and switches to the MSP" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    cpu.regs.psp = fixture.psp_top;
    cpu.regs.control |= regs.control_bits.spsel;
    try entry.take(&cpu, 11, 0x2000_0102);
    try std.testing.expectEqual(fixture.psp_top - 0x20, cpu.regs.psp);
    try std.testing.expectEqual(fixture.msp_top, cpu.regs.msp);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFD), cpu.regs.lr);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.control & regs.control_bits.spsel);
    try std.testing.expectEqual(fixture.msp_top, cpu.regs.sp());
}

test "entry from Handler mode nests on the MSP" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    cpu.regs.xpsr |= 14; // in PendSV
    try entry.take(&cpu, 11, 0x2000_0102);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFF1), cpu.regs.lr);
    try std.testing.expectEqual(@as(u32, 14), ram.word(cpu.regs.msp + 28) & regs.xpsr_bits.ipsr);
}

test "an unreadable vector leaves the registers alone" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    cpu.vtor = 0x1000_0000;
    const before = cpu.regs;
    try std.testing.expectError(error.Unmapped, entry.take(&cpu, 11, 0x2000_0102));
    try std.testing.expectEqual(before, cpu.regs);
}

test "the table the core reset from stands in while nothing answers at VTOR" {
    var ram: fixture.Ram = .{};
    const cpu = try fixture.boot(&ram);
    try std.testing.expectEqual(fixture.base, entry.vectorTable(&cpu));
}

test "entry with an FP context stacks the extended frame and clears FPCA" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    cpu.regs.control |= regs.control_bits.fpca;
    for (0..16) |i| cpu.fp.bank.writeS(@intCast(i), 0x4000_0000 + @as(u32, @intCast(i)));
    cpu.fp.bank.writeS(16, 0xDEAD_BEEF);
    cpu.fp.fpscr = ra8.core.fpu.fpscr.Fpscr.fromBits(0x0300_0000);
    try entry.take(&cpu, 11, 0x2000_0102);
    const sp = fixture.msp_top - 0x68;
    try std.testing.expectEqual(sp, cpu.regs.msp);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFE9), cpu.regs.lr);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.control & regs.control_bits.fpca);
    try std.testing.expectEqual(@as(u32, 0x2000_0102), ram.word(sp + 0x18));
    try std.testing.expectEqual(@as(u32, 0x4000_0000), ram.word(sp + 0x20));
    try std.testing.expectEqual(@as(u32, 0x4000_000F), ram.word(sp + 0x5C));
    try std.testing.expectEqual(@as(u32, 0x0300_0000), ram.word(sp + 0x60));
    // S16 is not part of this frame; the Secure extension is RA8EMU-165.
    try std.testing.expectEqual(@as(u32, 0), ram.word(sp + 0x64));
}

test "entry without an FP context keeps the basic frame and FType set" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    cpu.fp.bank.writeS(0, 0x4000_0000);
    try entry.take(&cpu, 11, 0x2000_0102);
    try std.testing.expectEqual(fixture.msp_top - 0x20, cpu.regs.msp);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFF9), cpu.regs.lr);
}

test "an SVC inside an IT block: entry clears ITSTATE, the frame keeps it, return restores it" {
    var ram: fixture.Ram = .{};
    // itt ne ; svc #0 ; movs r0, #1 (movne inside the block)
    ram.putWord(fixture.code, 0xDF00_BF1C);
    ram.putHalf(fixture.code + 4, 0x2001);
    ram.putHalf(fixture.handler, 0x4770); // bx lr
    var cpu = try fixture.boot(&ram);
    const it_state = ra8.core.cpu.it_state;
    try std.testing.expectEqual(@as(?ra8.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(@as(?ra8.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(fixture.handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.xpsr & entry.it_bits);
    // The SVC moved the block on: NE with one instruction left.
    try std.testing.expectEqual(@as(u8, 0x18), it_state.get(ram.word(cpu.regs.sp() + 28)));
    try std.testing.expectEqual(@as(?ra8.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(fixture.code + 4, cpu.regs.pc);
    try std.testing.expectEqual(@as(u8, 0x18), it_state.get(cpu.regs.xpsr));
    try std.testing.expectEqual(@as(?ra8.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(@as(u32, 1), cpu.regs.low[0]);
    try std.testing.expectEqual(@as(u8, 0), it_state.get(cpu.regs.xpsr));
}
