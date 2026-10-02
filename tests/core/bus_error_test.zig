//! Tests for src/core/bus_error.zig, against a real engine.

const std = @import("std");
const ra8 = @import("ra8");
const engine = ra8.core.engine;
const memmap = ra8.core.memmap;
const bus = ra8.periph.fault_status.bus;
const Nvic = ra8.periph.nvic.Nvic;

const entry: u32 = memmap.sram_base + 0x2000;
const table: u32 = memmap.sram_base + 0x6000;
const handlers: u32 = memmap.sram_base + 0x7000;
/// Nothing on the board maps this, so a store to it is refused.
const nowhere: u32 = 0xA000_0010;

/// A core with a vector table whose every handler is `b .` at
/// `handlers + 0x10 * n`, and `str r1, [r0]; b .` at the entry.
fn bench(watch: *engine.Watch, shcsr: u32) !engine.Engine {
    var core = try engine.Engine.open();
    errdefer core.close();
    try core.mapBoardRam();
    try core.attachWatch(watch);
    var number: u32 = 0;
    while (number < 16) : (number += 1) {
        try core.writeWord(table + 4 * number, handlers + 0x10 * number + 1);
        try core.writeWord(handlers + 0x10 * number, 0xE7FE_E7FE);
    }
    try core.writeWord(memmap.scb.vtor, table);
    try core.writeWord(memmap.scb.shcsr, shcsr);
    try core.writeWord(entry, 0xE7FE_6001);
    try core.setRegister(.sp, memmap.sram_base + 0x8000);
    try core.setRegister(.r0, nowhere);
    try core.setRegister(.r1, 0x1234);
    return core;
}

test "a refused store ends the run when the run did not opt in" {
    var watch = engine.Watch{};
    var core = try bench(&watch, 1 << 17);
    defer core.close();
    var unit = Nvic{};
    const ended = try core.run(entry, 20, .{ .watch = &watch, .interrupts = &unit });
    try std.testing.expect(ended != null);
    try std.testing.expectEqual(@as(u32, 0), try core.readWord(memmap.scb.cfsr));
}

test "an opted-in run takes BusFault with BFAR and the store stacked" {
    var watch = engine.Watch{};
    var core = try bench(&watch, 1 << 17);
    defer core.close();
    var unit = Nvic{};
    var tally = bus.Tally{};
    const ended = try core.run(entry, 20, .{ .watch = &watch, .interrupts = &unit, .bus_errors = &tally });
    try std.testing.expect(ended == null);
    try std.testing.expectEqual(@as(u32, 1), tally.raised);
    try std.testing.expectEqual(@as(u32, 0), tally.escalated);
    try std.testing.expectEqual(handlers + 0x50, try core.register(.pc));
    try std.testing.expectEqual(@as(u32, (1 << 9) | (1 << 15)), try core.readWord(memmap.scb.cfsr));
    try std.testing.expectEqual(nowhere, try core.readWord(bus.bfar));
    const sp = try core.register(.sp);
    try std.testing.expectEqual(entry, try core.readWord(sp + 24));
}

test "an opted-in run with BusFault disabled escalates to HardFault" {
    var watch = engine.Watch{};
    var core = try bench(&watch, 0);
    defer core.close();
    var unit = Nvic{};
    var tally = bus.Tally{};
    const ended = try core.run(entry, 20, .{ .watch = &watch, .interrupts = &unit, .bus_errors = &tally });
    try std.testing.expect(ended == null);
    try std.testing.expectEqual(@as(u32, 1), tally.escalated);
    try std.testing.expectEqual(handlers + 0x30, try core.register(.pc));
    try std.testing.expectEqual(@as(u32, 1 << 30), try core.readWord(memmap.scb.hfsr));
}
