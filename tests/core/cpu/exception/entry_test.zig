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
