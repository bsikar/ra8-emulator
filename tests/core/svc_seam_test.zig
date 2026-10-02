//! RA8EMU-54: the two backends take a module's SVC the same way.
//!
//! On Unicorn, SVCall exists only because src/core/svc_trap.zig raises it
//! when a run stops on an `svc`. The Zig core takes it itself
//! (src/core/cpu/ops/svc.zig and exception/entry.zig). A module reaches the
//! kernel only through SVC, so both must land in the same handler with the
//! same frame. This runs one program on each and compares.
const std = @import("std");
const ra8 = @import("ra8");
const engine = ra8.core.engine;
const memmap = ra8.core.memmap;
const svc_trap = ra8.core.svc_trap;
const regs = ra8.core.cpu.regs;
const Cpu = ra8.core.cpu.cpu.Cpu;
const Stop = ra8.core.cpu.cpu.Stop;
const EngineBus = ra8.core.cpu.engine_bus.EngineBus;
const Nvic = ra8.periph.nvic.Nvic;

const entry: u32 = memmap.sram_base + 0x2000;
const table: u32 = memmap.sram_base + 0x6000;
const handlers: u32 = memmap.sram_base + 0x7000;
const stack: u32 = memmap.sram_base + 0x8000;
const handler: u32 = handlers + 0x10 * svc_trap.svcall;

/// Reset vectors to `entry` on `stack`, every other handler `b .`, and
/// `movs r0, #0x5A; svc #5; b .` at the entry.
fn bench() !engine.Engine {
    var core = try engine.Engine.open();
    errdefer core.close();
    try core.mapBoardRam();
    var number: u32 = 2;
    while (number < 16) : (number += 1) {
        try core.writeWord(table + 4 * number, handlers + 0x10 * number + 1);
        try core.writeWord(handlers + 0x10 * number, 0xE7FE_E7FE);
    }
    try core.writeWord(table, stack);
    try core.writeWord(table + 4, entry + 1);
    try core.writeWord(memmap.scb.vtor, table);
    try core.writeWord(entry, 0xDF05_205A);
    try core.writeWord(entry + 4, 0xE7FE_E7FE);
    return core;
}

/// The SVCall handler a kernel dispatch boils down to: put a result in the
/// stacked r0 and return. `movs r1, #0x77; str r1, [sp]; bx lr`.
fn returning() !engine.Engine {
    var core = try bench();
    errdefer core.close();
    try core.writeWord(handler, 0x9100_2177);
    try core.writeWord(handler + 4, 0xE7FE_4770);
    return core;
}

/// Where a thread stands after its SVC came back.
const Back = struct {
    pc: u32,
    sp: u32,
    ipsr: u32,
    r0: u32,
};

fn unicornBack() !Back {
    var core = try returning();
    defer core.close();
    try core.setRegister(.sp, stack);
    var unit = Nvic{};
    try std.testing.expect(try core.run(entry, 20, .{ .interrupts = &unit }) == null);
    return .{
        .pc = try core.register(.pc),
        .sp = try core.register(.sp),
        .ipsr = (try core.register(.xpsr)) & regs.xpsr_bits.ipsr,
        .r0 = try core.register(.r0),
    };
}

fn zigBack() !Back {
    var core = try returning();
    defer core.close();
    var memory: EngineBus = .{ .core = &core };
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(table);
    try std.testing.expect(cpu.run(8) == Stop.count);
    return .{
        .pc = cpu.regs.pc,
        .sp = cpu.regs.msp,
        .ipsr = cpu.regs.xpsr & regs.xpsr_bits.ipsr,
        .r0 = cpu.regs.get(0),
    };
}

const Landing = struct {
    pc: u32,
    sp: u32,
    ipsr: u32,
    lr: u32,
    stacked_r0: u32,
    stacked_pc: u32,
};

fn unicorn() !Landing {
    var core = try bench();
    defer core.close();
    try core.setRegister(.sp, stack);
    var unit = Nvic{};
    try std.testing.expect(try core.run(entry, 20, .{ .interrupts = &unit }) == null);
    const sp = try core.register(.sp);
    return .{
        .pc = try core.register(.pc),
        .sp = sp,
        .ipsr = (try core.register(.xpsr)) & regs.xpsr_bits.ipsr,
        .lr = try core.register(.lr),
        .stacked_r0 = try core.readWord(sp),
        .stacked_pc = try core.readWord(sp + 24),
    };
}

fn zigCore() !Landing {
    var core = try bench();
    defer core.close();
    var memory: EngineBus = .{ .core = &core };
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(table);
    try std.testing.expect(cpu.run(4) == Stop.count);
    const sp = cpu.regs.msp;
    return .{
        .pc = cpu.regs.pc,
        .sp = sp,
        .ipsr = cpu.regs.xpsr & regs.xpsr_bits.ipsr,
        .lr = cpu.regs.lr,
        .stacked_r0 = try core.readWord(sp),
        .stacked_pc = try core.readWord(sp + 24),
    };
}

test "an SVC lands in SVCall with the same frame on both backends" {
    const theirs = try unicorn();
    const mine = try zigCore();
    try std.testing.expectEqual(handler, mine.pc);
    try std.testing.expectEqual(@as(u32, svc_trap.svcall), mine.ipsr);
    try std.testing.expectEqual(entry + 4, mine.stacked_pc);
    try std.testing.expectEqual(@as(u32, 0x5A), mine.stacked_r0);
    try std.testing.expectEqual(stack - 0x20, mine.sp);
    try std.testing.expectEqualDeep(theirs, mine);
}

test "an SVC handler's result comes back in r0 the same way on both backends" {
    const theirs = try unicornBack();
    const mine = try zigBack();
    try std.testing.expectEqual(entry + 4, mine.pc);
    try std.testing.expectEqual(stack, mine.sp);
    try std.testing.expectEqual(@as(u32, 0), mine.ipsr);
    try std.testing.expectEqual(@as(u32, 0x77), mine.r0);
    try std.testing.expectEqualDeep(theirs, mine);
}
