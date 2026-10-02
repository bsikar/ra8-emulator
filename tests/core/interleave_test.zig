//! Tests for src/core/interleave.zig.

const std = @import("std");
const ra8 = @import("ra8");
const mod = ra8.core.interleave;
const second_core = ra8.core.second_core;
const engine = ra8.core.engine;
const memmap = ra8.core.memmap;
const clocks = ra8.periph.clocks;
const Engine = engine.Engine;

/// CPU0 on board RAM, and CPU1 built into storage the caller holds sharing
/// it: CPU1's watch is registered by address, so it must not move.
fn pair(cpu1: *second_core.Second) !Engine {
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
    var cpu1: second_core.Second = undefined;
    var cpu0 = try pair(&cpu1);
    defer cpu0.close();
    defer cpu1.close();

    // Both cores sit on nops in shared SRAM, at addresses of their own.
    try cpu0.writeWord(memmap.sram_base + 0x1000, 0xBF00_BF00);
    try cpu1.core.writeWord(memmap.sram_base + 0x2000, 0xBF00_BF00);
    cpu1.pc = memmap.sram_base + 0x2000;

    _ = try mod.interleave(cpu0, memmap.sram_base + 0x1000, 2 * second_core.limits.round, .{}, &cpu1);
    try std.testing.expect(cpu1.turns >= 1);
    try std.testing.expect(cpu1.ran >= second_core.limits.round);
}

test "a core that faults is halted rather than restarted every round" {
    var cpu1: second_core.Second = undefined;
    var cpu0 = try pair(&cpu1);
    defer cpu0.close();
    defer cpu1.close();

    try cpu0.writeWord(memmap.sram_base + 0x1000, 0xBF00_BF00);
    // Nothing is mapped here, so the first turn faults.
    cpu1.pc = 0x1000_0000;

    _ = try mod.interleave(cpu0, memmap.sram_base + 0x1000, 4 * second_core.limits.round, .{}, &cpu1);
    try std.testing.expect(cpu1.fault != null);
    try std.testing.expectEqual(@as(usize, 1), cpu1.turns);
}

/// One interleaved run of two counting loops (`adds r0, #1; b` back), three
/// of CPU0's rounds long, and what each core counted and was charged.
const Race = struct {
    cpu0_count: u32,
    cpu1_count: u32,
    cpu0_charged: u64,
    cpu1_charged: u64,
    turns: usize,

    const loop: u32 = 0xE7FD_3001;
    const cpu0_entry: u32 = memmap.sram_base + 0x3000;
    const cpu1_entry: u32 = memmap.sram_base + 0x4000;

    fn run() !Race {
        var cpu1: second_core.Second = undefined;
        var cpu0 = try pair(&cpu1);
        defer cpu0.close();
        defer cpu1.close();
        try cpu1.core.writeWord(cpu1_entry, loop);
        cpu1.pc = cpu1_entry;
        try cpu0.writeWord(cpu0_entry, loop);
        var cpu0_clock = clocks.Clocks{};
        const session: engine.Session = .{ .timebase = &cpu0_clock };
        _ = try mod.interleave(cpu0, cpu0_entry, 3 * second_core.limits.round, session, &cpu1);
        return .{
            .cpu0_count = try cpu0.register(.r0),
            .cpu1_count = try cpu1.core.register(.r0),
            .cpu0_charged = cpu0_clock.elapsed,
            .cpu1_charged = cpu1.timebase.elapsed,
            .turns = cpu1.turns,
        };
    }
};

test "each core is charged only for its own instructions" {
    const race = try Race.run();
    try std.testing.expectEqual(@as(u64, 3 * second_core.limits.round), race.cpu0_charged);
    try std.testing.expectEqual(@as(u64, 3 * second_core.limits.round), race.cpu1_charged);
    try std.testing.expectEqual(@as(usize, 3), race.turns);
    try std.testing.expect(race.cpu0_count > 0 and race.cpu1_count > 0);
}

test "the same pair of images interleaves the same way every run" {
    const first = try Race.run();
    const second = try Race.run();
    try std.testing.expect(std.meta.eql(first, second));
}
