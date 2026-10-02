//! Tests for src/periph/usage_fault.zig, against a real engine.

const std = @import("std");
const ra8 = @import("ra8");
const engine = ra8.core.engine;
const memmap = ra8.core.memmap;
const fault_status = ra8.periph.fault_status;
const usage = fault_status.usage;
const Nvic = ra8.periph.nvic.Nvic;

const entry: u32 = memmap.sram_base + 0x2000;
const table: u32 = memmap.sram_base + 0x6000;
const handlers: u32 = memmap.sram_base + 0x7000;

/// A core whose every handler is `b .` at `handlers + 0x10 * n`.
fn bench(shcsr: u32) !engine.Engine {
    var core = try engine.Engine.open();
    errdefer core.close();
    try core.mapBoardRam();
    var number: u32 = 0;
    while (number < 16) : (number += 1) {
        try core.writeWord(table + 4 * number, handlers + 0x10 * number + 1);
        try core.writeWord(handlers + 0x10 * number, 0xE7FE_E7FE);
    }
    try core.writeWord(memmap.scb.vtor, table);
    try core.writeWord(memmap.scb.shcsr, shcsr);
    try core.setRegister(.sp, memmap.sram_base + 0x8000);
    return core;
}

test "an undefined instruction with UsageFault enabled vectors to 6" {
    var core = try bench(1 << 18);
    defer core.close();
    var unit = Nvic{};
    const taken = try usage.raise(&core, &unit, .undefinstr, entry);
    try std.testing.expectEqual(@as(u16, 6), taken.number);
    try std.testing.expect(!taken.escalated);
    try std.testing.expectEqual(handlers + 0x60, try core.register(.pc));
    try std.testing.expectEqual(@as(u32, 1 << 16), try core.readWord(memmap.scb.cfsr));
    try std.testing.expectEqual(entry, try core.readWord((try core.register(.sp)) + 24));
}

test "a UsageFault with USGFAULTENA clear escalates with HFSR.FORCED" {
    var core = try bench(0);
    defer core.close();
    var unit = Nvic{};
    const taken = try usage.raise(&core, &unit, .divbyzero, entry);
    try std.testing.expectEqual(@as(u16, 3), taken.number);
    try std.testing.expect(taken.escalated);
    try std.testing.expectEqual(@as(u32, 1 << 30), try core.readWord(memmap.scb.hfsr));
    try std.testing.expectEqual(@as(u32, 1 << 25), try core.readWord(memmap.scb.cfsr));
}

test "UFSR bits from earlier faults are kept" {
    var core = try bench(1 << 18);
    defer core.close();
    try core.writeWord(memmap.scb.cfsr, 1 << 17);
    var unit = Nvic{};
    _ = try usage.raise(&core, &unit, .nocp, entry);
    try std.testing.expectEqual(@as(u32, (1 << 17) | (1 << 19)), try core.readWord(memmap.scb.cfsr));
}

test "a MemManage or BusFault cause is refused and latches nothing" {
    var core = try bench(1 << 18);
    defer core.close();
    var unit = Nvic{};
    try std.testing.expectError(usage.Error.NotUsageFault, usage.raise(&core, &unit, .preciserr, entry));
    try std.testing.expectError(usage.Error.NotUsageFault, usage.raise(&core, &unit, .daccviol, entry));
    try std.testing.expectEqual(@as(u32, 0), try core.readWord(memmap.scb.cfsr));
    try std.testing.expectEqual(@as(u8, 0), unit.depth);
}
