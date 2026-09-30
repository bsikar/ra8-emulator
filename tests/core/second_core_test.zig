//! Tests for src/core/second_core.zig.
const std = @import("std");
const ra8 = @import("ra8");
const mod = ra8.core.second_core;
const engine = ra8.core.engine;
const memmap = ra8.core.memmap;
const Engine = engine.Engine;
const Board = ra8.board.Board;
const sau = ra8.periph.sau;

/// A thumb image is not needed to test the wiring: what matters is that the
/// second core is put in front of the first core's board and takes turns.
///
/// CPU1 is built into storage the caller holds, the way `open` requires:
/// its watch is registered with Unicorn by address, so a `Second` moved
/// after that leaves the hook pointing at where it used to be.
fn pair(cpu1: *mod.Second) !Engine {
    var cpu0 = try Engine.open();
    errdefer cpu0.close();
    try cpu0.mapBoardRam();
    cpu1.* = .{ .core = try Engine.open() };
    errdefer cpu1.close();
    try cpu1.core.shareBoardRamWith(&cpu0);
    try cpu1.core.attachWatch(&cpu1.watch);
    return cpu0;
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
    var cpu1: mod.Second = undefined;
    var cpu0 = try pair(&cpu1);
    defer cpu0.close();
    defer cpu1.close();

    // Both cores sit on nops in shared SRAM, at addresses of their own.
    try cpu0.writeWord(memmap.sram_base + 0x1000, 0xBF00_BF00);
    try cpu1.core.writeWord(memmap.sram_base + 0x2000, 0xBF00_BF00);
    cpu1.pc = memmap.sram_base + 0x2000;

    _ = try mod.interleave(cpu0, memmap.sram_base + 0x1000, 2 * mod.limits.round, .{}, &cpu1);
    try std.testing.expect(cpu1.turns >= 1);
    try std.testing.expect(cpu1.ran >= mod.limits.round);
}

test "a core that faults is halted rather than restarted every round" {
    var cpu1: mod.Second = undefined;
    var cpu0 = try pair(&cpu1);
    defer cpu0.close();
    defer cpu1.close();

    try cpu0.writeWord(memmap.sram_base + 0x1000, 0xBF00_BF00);
    // Nothing is mapped here, so the first turn faults.
    cpu1.pc = 0x1000_0000;

    _ = try mod.interleave(cpu0, memmap.sram_base + 0x1000, 4 * mod.limits.round, .{}, &cpu1);
    try std.testing.expect(cpu1.fault != null);
    try std.testing.expectEqual(@as(usize, 1), cpu1.turns);
}

test "what one core stores in shared SRAM the other core reads" {
    var cpu1: mod.Second = undefined;
    var cpu0 = try pair(&cpu1);
    defer cpu0.close();
    defer cpu1.close();

    try cpu1.core.writeWord(memmap.ns_sram_base + 0x100200, 0xB055_A55A);
    try std.testing.expectEqual(
        @as(u32, 0xB055_A55A),
        try cpu0.readWord(memmap.sram_base + 0x100200),
    );
}

test "no path named means no second core, and the storage is left alone" {
    var cpu0 = try Engine.open();
    defer cpu0.close();
    try cpu0.mapBoardRam();
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var storage = mod.Second{ .core = undefined, .turns = 7 };
    const none = try mod.start(std.testing.allocator, &cpu0, &board, null, &storage);
    try std.testing.expect(none == null);
    try std.testing.expectEqual(@as(usize, 7), storage.turns);
}

test "a second core carries an SAU of its own, not the board's" {
    var cpu1: mod.Second = undefined;
    var cpu0 = try pair(&cpu1);
    defer cpu0.close();
    defer cpu1.close();

    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    try std.testing.expect(&cpu1.partitions != &board.partitions);
}

test "a fresh second core's SAU is quiet, so it prints no line" {
    var cpu1 = mod.Second{ .core = undefined };
    try std.testing.expect(cpu1.partitions.quiet());
}

test "one core's SAU map does not land in the other's table" {
    var mine = sau.Sau.init();
    var theirs = sau.Sau.init();

    // CPU0 programmes region 0 as Non-Secure Callable.
    _ = mine.observe(memmap.sau.rnr, 0);
    _ = mine.observe(memmap.sau.rbar, 0x0200_0000);
    _ = mine.observe(memmap.sau.rlar, 0x0207_FFE0 | sau.field.rlar_enable | sau.field.rlar_nsc);
    // CPU1 programmes its own region 0 as plain Non-Secure.
    _ = theirs.observe(memmap.sau.rnr, 0);
    _ = theirs.observe(memmap.sau.rbar, 0x5000_0000);
    _ = theirs.observe(memmap.sau.rlar, 0x5FFF_FFE0 | sau.field.rlar_enable);

    try std.testing.expectEqual(@as(u8, 1), mine.callable());
    try std.testing.expectEqual(@as(u8, 0), theirs.callable());
    try std.testing.expectEqual(@as(u32, 0x0200_0000), mine.table[0].base);
    try std.testing.expectEqual(@as(u32, 0x5000_0000), theirs.table[0].base);
}

test "a round is the chunk boundary" {
    try std.testing.expectEqual(ra8.core.cadence.instructions, mod.limits.round);
}
