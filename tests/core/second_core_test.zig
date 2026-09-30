//! Tests for src/core/second_core.zig.
const std = @import("std");
const ra8 = @import("ra8");
const mod = ra8.core.second_core;
const engine = ra8.core.engine;
const memmap = ra8.core.memmap;
const Engine = engine.Engine;
const Board = ra8.board.Board;

/// A thumb image is not needed to test the wiring: what matters is that the
/// second core is put in front of the first core's board and takes turns.
fn pair() !struct { cpu0: Engine, cpu1: mod.Second } {
    var cpu0 = try Engine.open();
    errdefer cpu0.close();
    try cpu0.mapBoardRam();
    var cpu1 = mod.Second{ .core = try Engine.open() };
    errdefer cpu1.close();
    try cpu1.core.shareBoardRamWith(&cpu0);
    try cpu1.core.attachWatch(&cpu1.watch);
    return .{ .cpu0 = cpu0, .cpu1 = cpu1 };
}

test "no second core runs exactly what the engine would have run" {
    var cpu0 = try Engine.open();
    defer cpu0.close();
    try cpu0.mapBoardRam();
    // bx lr into an unmapped return address faults; the point is that
    // interleave hands the call straight through rather than rounding it.
    try cpu0.writeWord(memmap.sram_base, 0xBF00_BF00);
    const fault = try mod.interleave(cpu0, memmap.sram_base, 4, .{}, null);
    try std.testing.expect(fault == null);
}

test "a second core takes a turn between the first core's rounds" {
    var both = try pair();
    defer both.cpu0.close();
    defer both.cpu1.close();

    // Both cores sit on nops in shared SRAM, at addresses of their own.
    try both.cpu0.writeWord(memmap.sram_base + 0x1000, 0xBF00_BF00);
    try both.cpu1.core.writeWord(memmap.sram_base + 0x2000, 0xBF00_BF00);
    both.cpu1.pc = memmap.sram_base + 0x2000;

    _ = try mod.interleave(both.cpu0, memmap.sram_base + 0x1000, 2 * mod.limits.round, .{}, &both.cpu1);
    try std.testing.expect(both.cpu1.turns >= 1);
    try std.testing.expect(both.cpu1.ran >= mod.limits.round);
}

test "a core that faults is halted rather than restarted every round" {
    var both = try pair();
    defer both.cpu0.close();
    defer both.cpu1.close();

    try both.cpu0.writeWord(memmap.sram_base + 0x1000, 0xBF00_BF00);
    // Nothing is mapped here, so the first turn faults.
    both.cpu1.pc = 0x1000_0000;

    _ = try mod.interleave(both.cpu0, memmap.sram_base + 0x1000, 4 * mod.limits.round, .{}, &both.cpu1);
    try std.testing.expect(both.cpu1.fault != null);
    try std.testing.expectEqual(@as(usize, 1), both.cpu1.turns);
}

test "what one core stores in shared SRAM the other core reads" {
    var both = try pair();
    defer both.cpu0.close();
    defer both.cpu1.close();

    try both.cpu1.core.writeWord(memmap.ns_sram_base + 0x100200, 0xB055_A55A);
    try std.testing.expectEqual(
        @as(u32, 0xB055_A55A),
        try both.cpu0.readWord(memmap.sram_base + 0x100200),
    );
}

test "no path named means no second core" {
    var cpu0 = try Engine.open();
    defer cpu0.close();
    try cpu0.mapBoardRam();
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    const none = try mod.start(std.testing.allocator, &cpu0, &board, null);
    try std.testing.expect(none == null);
}

test "a round is the chunk boundary" {
    try std.testing.expectEqual(ra8.core.cadence.instructions, mod.limits.round);
}
