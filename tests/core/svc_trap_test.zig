//! Tests for src/core/svc_trap.zig, against a real engine.

const std = @import("std");
const ra8 = @import("ra8");
const engine = ra8.core.engine;
const memmap = ra8.core.memmap;
const svc_trap = ra8.core.svc_trap;
const Nvic = ra8.periph.nvic.Nvic;

const entry: u32 = memmap.sram_base + 0x2000;
const table: u32 = memmap.sram_base + 0x6000;
const handlers: u32 = memmap.sram_base + 0x7000;
const stack: u32 = memmap.sram_base + 0x8000;

/// A core with every handler `b .` at `handlers + 0x10 * n`, and
/// `svc #5; b .` at the entry.
fn bench() !engine.Engine {
    var core = try engine.Engine.open();
    errdefer core.close();
    try core.mapBoardRam();
    var number: u32 = 0;
    while (number < 16) : (number += 1) {
        try core.writeWord(table + 4 * number, handlers + 0x10 * number + 1);
        try core.writeWord(handlers + 0x10 * number, 0xE7FE_E7FE);
    }
    try core.writeWord(memmap.scb.vtor, table);
    try core.writeWord(entry, 0xE7FE_DF05);
    try core.setRegister(.sp, stack);
    return core;
}

test "an SVC from unprivileged thread mode enters SVCall with the next instruction stacked" {
    var core = try bench();
    defer core.close();
    try core.setRegister(.control, 1);
    var unit = Nvic{};
    const ended = try core.run(entry, 20, .{ .interrupts = &unit });
    try std.testing.expect(ended == null);
    try std.testing.expectEqual(handlers + 0x10 * svc_trap.svcall, try core.register(.pc));
    const frame = try core.register(.sp);
    try std.testing.expectEqual(entry + 2, try core.readWord(frame + 24));
    try std.testing.expectEqual(@as(u32, 0), try core.readWord(memmap.scb.hfsr));
}

test "an SVC with no controller still ends the run" {
    var core = try bench();
    defer core.close();
    const ended = try core.run(entry, 20, .{});
    try std.testing.expect(ended != null);
}

test "an SVC under PRIMASK escalates to HardFault and owes FORCED" {
    var core = try bench();
    defer core.close();
    try core.setRegister(.primask, 1);
    var unit = Nvic{};
    const ended = try core.run(entry, 20, .{ .interrupts = &unit });
    try std.testing.expect(ended == null);
    try std.testing.expectEqual(handlers + 0x30, try core.register(.pc));
    try std.testing.expectEqual(@as(u32, 1 << 30), try core.readWord(memmap.scb.hfsr));
}

test "after recognises only a T1 SVC before the PC" {
    var core = try bench();
    defer core.close();
    try std.testing.expect(svc_trap.after(&core, entry + 2));
    try std.testing.expect(!svc_trap.after(&core, entry + 4));
    try std.testing.expect(!svc_trap.after(&core, 0));
}

test "route takes SVCall at its SHPR2 priority unless it cannot preempt" {
    const taken = svc_trap.route(0x4000_0000, null);
    try std.testing.expectEqual(svc_trap.svcall, taken.number);
    try std.testing.expectEqual(@as(u8, 0x40), taken.priority);
    try std.testing.expect(!taken.escalated);
    try std.testing.expect(svc_trap.route(0x4000_0000, 0x40).escalated);
    try std.testing.expect(!svc_trap.route(0x4000_0000, 0x80).escalated);
}
