//! Exercises the DIV_0_TRP code hook through Unicorn's live engine.
const std = @import("std");
const ra8 = @import("ra8");
const engine = ra8.core.engine;
const fault_hook = ra8.core.fault.divide_hook;
const memmap = ra8.core.memmap;
const nvic = ra8.periph.nvic;

const image: u32 = 0x0200_0000;
const code: u32 = image + 0x100;
const usage: u32 = image + 0x200;
const hard: u32 = image + 0x220;
const stack: u32 = 0x2000_1000;
const div_0_trp: u32 = 1 << 4;
const usgfaultena: u32 = 1 << 18;
const divbyzero: u32 = 1 << 25;
const forced: u32 = 1 << 30;

/// A valid vector table, one divide site and loops for each fault handler.
fn boot(
    core: *engine.Engine,
    controller: *nvic.Nvic,
    trap: *fault_hook.Trap,
    shcsr: u32,
    ccr: u32,
    hw1: u16,
) !void {
    try core.map(image, 0x1000);
    try core.map(0x2000_0000, 0x1000);
    try core.map(0xE000_E000, 0x1000);
    try core.writeWord(image, stack);
    try core.writeWord(image + 4, code | 1);
    try core.writeWord(image + 3 * 4, hard | 1);
    try core.writeWord(image + 6 * 4, usage | 1);
    try core.write(code, &.{ @truncate(hw1), @truncate(hw1 >> 8), 0xF1, 0xF2, 0xFE, 0xE7 });
    try core.write(usage, &.{ 0xFE, 0xE7 });
    try core.write(hard, &.{ 0xFE, 0xE7 });
    try core.writeWord(memmap.scb.ccr, ccr);
    try core.writeWord(memmap.scb.shcsr, shcsr);
    controller.* = .{ .vector_base = image };
    trap.* = .{ .core = core, .controller = controller };
    try fault_hook.hookAt(core.handle, code, trap);
    try core.resetFromVectorTable(image);
    try core.setRegister(.r0, 100);
    try core.setRegister(.r1, 0);
}

test "Unicorn takes UsageFault for SDIV and UDIV zero when enabled" {
    for ([_]u16{ 0xFB90, 0xFBB0 }) |hw1| {
        var core = try engine.Engine.open();
        defer core.close();
        var controller: nvic.Nvic = .{};
        var trap: fault_hook.Trap = undefined;
        try boot(&core, &controller, &trap, usgfaultena, div_0_trp, hw1);
        const ended = try core.runChunk(code, 1, null);
        try std.testing.expect(ended == null);
        try std.testing.expectEqual(@as(u32, 6), (try core.register(.xpsr)) & 0x1FF);
        try std.testing.expectEqual(divbyzero, try core.readWord(memmap.scb.cfsr));
        try std.testing.expectEqual(@as(u32, 0), try core.readWord(memmap.scb.hfsr));
        try std.testing.expectEqual(code, try core.readWord(try core.register(.sp) + 24));
        try std.testing.expectEqual(@as(u32, 1), trap.raised);
    }
}

test "Unicorn escalates a disabled UsageFault to forced HardFault" {
    var core = try engine.Engine.open();
    defer core.close();
    var controller: nvic.Nvic = .{};
    var trap: fault_hook.Trap = undefined;
    try boot(&core, &controller, &trap, 0, div_0_trp, 0xFBB0);
    const ended = try core.runChunk(code, 1, null);
    try std.testing.expect(ended == null);
    try std.testing.expectEqual(@as(u32, 3), (try core.register(.xpsr)) & 0x1FF);
    try std.testing.expectEqual(divbyzero, try core.readWord(memmap.scb.cfsr));
    try std.testing.expectEqual(forced, try core.readWord(memmap.scb.hfsr));
}

test "Unicorn leaves division alone when trapping is disabled or divisor is nonzero" {
    for ([_]struct { trap: u32, divisor: u32 }{
        .{ .trap = 0, .divisor = 0 },
        .{ .trap = div_0_trp, .divisor = 2 },
    }) |case| {
        var core = try engine.Engine.open();
        defer core.close();
        var controller: nvic.Nvic = .{};
        var trap: fault_hook.Trap = undefined;
        try boot(&core, &controller, &trap, usgfaultena, case.trap, 0xFBB0);
        if (case.divisor != 0) try core.setRegister(.r1, case.divisor);
        const ended = try core.runChunk(code, 1, null);
        try std.testing.expect(ended == null);
        try std.testing.expectEqual(@as(u32, 0), (try core.register(.xpsr)) & 0x1FF);
        try std.testing.expectEqual(@as(u32, 0), try core.readWord(memmap.scb.cfsr));
        try std.testing.expectEqual(@as(u32, 0), trap.raised);
    }
}
