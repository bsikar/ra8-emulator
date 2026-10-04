//! Covers src/core/cpu/exception/lazy_fault.zig through Cpu.step: a
//! deferred FP push the bus refuses is BusFault LSPERR, escalated to
//! HardFault FORCED when BusFault is disabled.
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("ram.zig");
const memmap = ra8.core.memmap;
const Cpu = ra8.core.cpu.cpu.Cpu;
const Stop = ra8.core.cpu.cpu.Stop;

const hard_handler: u32 = fixture.base + 0x1E0;
const bus_handler: u32 = fixture.base + 0x1C0;
const busfaultena: u32 = 1 << 17;
const lsperr: u32 = 1 << 13;
const forced: u32 = 1 << 30;
const unmapped: u32 = 0x1000_0000;
const bfar: u32 = 0xE000_ED38;

/// VADD.F32 s0, s1, s2 with a deferred FP push pending into `fpcar`.
fn lazyStep(ram: *fixture.Ram, shcsr: u32, fpcar: u32) !Cpu {
    ram.putWord(fixture.base + 3 * 4, hard_handler | 1);
    ram.putWord(fixture.base + 5 * 4, bus_handler | 1);
    ram.putWord(memmap.scb.shcsr, shcsr);
    ram.putHalf(fixture.code, 0xEE30);
    ram.putHalf(fixture.code + 2, 0x0A81);
    var cpu = try fixture.boot(ram);
    cpu.fp.context.writeFpcar(fpcar);
    cpu.fp.context.fpccr.lspact = 1;
    cpu.fp.context.fpccr.hfrdy = 1;
    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    return cpu;
}

test "a deferred FP push the bus refuses is BusFault LSPERR, the FP op stacked" {
    var ram: fixture.Ram = .{};
    const cpu = try lazyStep(&ram, busfaultena, unmapped);
    try std.testing.expectEqual(bus_handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 5), cpu.regs.xpsr & 0x1FF);
    try std.testing.expectEqual(lsperr, ram.word(memmap.scb.cfsr));
    try std.testing.expectEqual(@as(u32, 0), ram.word(bfar));
    try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.hfsr));
    try std.testing.expectEqual(@as(u1, 1), cpu.fp.context.fpccr.lspact);
    try std.testing.expectEqual(fixture.code, ram.word(fixture.msp_top - 8));
}

test "with BUSFAULTENA clear the LSPERR escalates to HardFault FORCED" {
    var ram: fixture.Ram = .{};
    const cpu = try lazyStep(&ram, 0, unmapped);
    try std.testing.expectEqual(hard_handler, cpu.regs.pc);
    try std.testing.expectEqual(lsperr, ram.word(memmap.scb.cfsr));
    try std.testing.expectEqual(forced, ram.word(memmap.scb.hfsr));
}

test "a push into mapped memory lands and the FP op runs" {
    var ram: fixture.Ram = .{};
    const cpu = try lazyStep(&ram, busfaultena, fixture.msp_top - 0x60);
    try std.testing.expectEqual(fixture.code + 4, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.cfsr));
    try std.testing.expectEqual(@as(u1, 0), cpu.fp.context.fpccr.lspact);
}
