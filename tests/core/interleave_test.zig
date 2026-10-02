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

test "a CPU1 clocked at a quarter of CPU0 runs a quarter of each round" {
    var cpu1: second_core.Second = undefined;
    var cpu0 = try pair(&cpu1);
    defer cpu0.close();
    defer cpu1.close();

    // The bring-up dividers: CPUCLK0 /1, CPUCLK1 /4 (SCKDIVCR2 0x2020).
    const dividers: u16 = 0x2020;
    cpu1.dividers = &dividers;
    try cpu0.writeWord(memmap.sram_base + 0x1000, 0xBF00_BF00);
    try cpu1.core.writeWord(memmap.sram_base + 0x2000, 0xBF00_BF00);
    cpu1.pc = memmap.sram_base + 0x2000;

    _ = try mod.interleave(cpu0, memmap.sram_base + 0x1000, 2 * second_core.limits.round, .{}, &cpu1);
    try std.testing.expectEqual(@as(usize, 2), cpu1.turns);
    try std.testing.expectEqual(@as(usize, second_core.limits.round / 2), cpu1.ran);
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
/// of CPU0's rounds long, under the SCKDIVCR2 word `dividers`, with both
/// SysTicks counting (no interrupt) over a 500-instruction period, and what
/// each core counted and was charged.
const Race = struct {
    cpu0_count: u32,
    cpu1_count: u32,
    cpu0_charged: u64,
    cpu1_charged: u64,
    turns: usize,
    cpu0_ticks: u64,
    cpu1_ticks: u64,

    const loop: u32 = 0xE7FD_3001;
    const cpu0_entry: u32 = memmap.sram_base + 0x3000;
    const cpu1_entry: u32 = memmap.sram_base + 0x4000;

    fn run(dividers: u16) !Race {
        var cpu1: second_core.Second = undefined;
        var cpu0 = try pair(&cpu1);
        defer cpu0.close();
        defer cpu1.close();
        cpu1.dividers = &dividers;
        for ([_]Engine{ cpu0, cpu1.core }) |core| {
            try core.writeWord(memmap.syst.rvr, 499);
            try core.writeWord(memmap.syst.cvr, 0);
            try core.writeWord(memmap.syst.csr, 0b101);
        }
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
            .cpu0_ticks = cpu0_clock.ticks,
            .cpu1_ticks = cpu1.timebase.ticks,
        };
    }
};

test "each core is charged only for its own instructions" {
    const race = try Race.run(0);
    try std.testing.expectEqual(@as(u64, 3 * second_core.limits.round), race.cpu0_charged);
    try std.testing.expectEqual(@as(u64, 3 * second_core.limits.round), race.cpu1_charged);
    try std.testing.expectEqual(@as(usize, 3), race.turns);
    try std.testing.expect(race.cpu0_count > 0 and race.cpu1_count > 0);
}

test "with both dividers at reset the two SysTicks count at the same rate" {
    const race = try Race.run(0);
    try std.testing.expect(race.cpu0_ticks > 0);
    try std.testing.expectEqual(race.cpu0_ticks, race.cpu1_ticks);
}

test "each core's SysTick counts at that core's own clock" {
    // SCKDIVCR2 0x2020: CPUCLK0 /1, CPUCLK1 /4. Same reload on both cores,
    // so CPU1's SysTick wraps a quarter as often as CPU0's.
    const race = try Race.run(0x2020);
    try std.testing.expectEqual(@as(u64, 3 * second_core.limits.round), race.cpu0_charged);
    try std.testing.expectEqual(@as(u64, 3 * second_core.limits.round / 4), race.cpu1_charged);
    try std.testing.expect(race.cpu1_ticks > 0);
    try std.testing.expectEqual(race.cpu0_ticks, 4 * race.cpu1_ticks);
}

test "the same pair of images interleaves the same way every run" {
    const first = try Race.run(0);
    const second = try Race.run(0);
    try std.testing.expect(std.meta.eql(first, second));
}

/// CPU0 sends 41 to CPU1 on IPC1 channel 2 and polls IPC0 channel 0 for the
/// answer; CPU1 polls channel 2, adds one and sends the result back on
/// channel 0. Both poll STA.RDY rather than take the receive interrupt,
/// which needs CPU1's ICU routing (RA8EMU-35). Literals: ch2 0x4002_0100,
/// ch0 0x4002_00C0.
const Mailbox = struct {
    const cpu0_entry: u32 = memmap.sram_base + 0x3000;
    const cpu1_entry: u32 = memmap.sram_base + 0x4000;
    // ldr r1,=ch2; ldr r2,=ch0; movs r0,#41; str r0,[r1,#8]
    // 1: ldr r3,[r2]; lsls r3,#15; bpl 1b; ldr r0,[r2,#12]; b .
    const cpu0_image = [_]u32{
        0x4A05_4904, 0x6088_2029, 0x03DB_6813, 0x68D0_D5FC,
        0xBF00_E7FE, 0x4002_0100, 0x4002_00C0,
    };
    // ldr r1,=ch2; ldr r2,=ch0; 1: ldr r3,[r1]; lsls r3,#15; bpl 1b
    // ldr r0,[r1,#12]; adds r0,#1; str r0,[r2,#8]; b .
    const cpu1_image = [_]u32{
        0x4A05_4904, 0x03DB_680B, 0x68C8_D5FC, 0x6090_3001,
        0xBF00_E7FE, 0x4002_0100, 0x4002_00C0,
    };

    fn load(core: Engine, base: u32, words: []const u32) !void {
        for (words, 0..) |word, i| try core.writeWord(base + @as(u32, @intCast(i)) * 4, word);
    }
};

test "a message CPU0 sends over IPC comes back from CPU1 answered" {
    var cpu0 = try Engine.open();
    defer cpu0.close();
    try cpu0.mapBoardRam();
    var board = ra8.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try board.attach(&cpu0);

    var cpu1: second_core.Second = .{ .core = try Engine.open() };
    defer cpu1.close();
    try cpu1.core.shareBoardRamWith(&cpu0);
    try cpu1.core.attachWatch(&cpu1.watch);
    try ra8.board.wiring.attachSecond(&board, &cpu1.core, .{
        .partitions = &cpu1.partitions,
        .regions = &cpu1.regions,
        .guard = &cpu1.guard,
        .identity = ra8.periph.cpuid.cpu1,
        .control = &cpu1.control,
        .clears = &cpu1.clears,
    });

    try Mailbox.load(cpu0, Mailbox.cpu0_entry, &Mailbox.cpu0_image);
    try Mailbox.load(cpu1.core, Mailbox.cpu1_entry, &Mailbox.cpu1_image);
    cpu1.pc = Mailbox.cpu1_entry;

    const round = second_core.limits.round;
    _ = try mod.interleave(cpu0, Mailbox.cpu0_entry, 3 * round, .{}, &cpu1);

    try std.testing.expectEqual(@as(u32, 42), try cpu0.register(.r0));
    try std.testing.expectEqual(@as(u32, 42), try cpu1.core.register(.r0));
    try std.testing.expect(cpu1.fault == null);
    const to_cpu1 = board.mailbox.channels[2];
    const to_cpu0 = board.mailbox.channels[0];
    try std.testing.expectEqual(@as(u32, 1), to_cpu1.pushes);
    try std.testing.expectEqual(@as(u32, 1), to_cpu1.pops);
    try std.testing.expectEqual(@as(u32, 1), to_cpu0.pushes);
    try std.testing.expectEqual(@as(u32, 1), to_cpu0.pops);
    try std.testing.expectEqual(@as(u32, 0), to_cpu0.lost + to_cpu1.lost);
}

test "an event INTSELR hands to CPU1 pends CPU1's NVIC and not CPU0's" {
    var cpu0 = try Engine.open();
    defer cpu0.close();
    try cpu0.mapBoardRam();
    var board = ra8.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try board.attach(&cpu0);

    var cpu1: second_core.Second = .{ .core = try Engine.open() };
    defer cpu1.close();
    try cpu1.core.shareBoardRamWith(&cpu0);
    try ra8.board.wiring.attachSecond(&board, &cpu1.core, .{
        .partitions = &cpu1.partitions,
        .regions = &cpu1.regions,
        .guard = &cpu1.guard,
        .identity = ra8.periph.cpuid.cpu1,
        .control = &cpu1.control,
        .clears = &cpu1.clears,
    });

    const icu = ra8.periph.icu;
    board.events.select.write(icu.intsel.wordAddress(0), 4, 1 << 0x12);
    board.events.cpu1[3] = 0x12;
    board.events.links[6] = 0x13;
    try board.raise(cpu0, 0x12);
    try board.raise(cpu0, 0x13);

    try std.testing.expectEqual(@as(u32, 1) << 3, try cpu1.core.readWord(memmap.nvic.ispr));
    try std.testing.expectEqual(@as(u32, 1) << 6, try cpu0.readWord(memmap.nvic.ispr));
}

/// CPU0 on nops and CPU1 on `wfe; movs r0, #7; b .`, run for `rounds`.
fn parkedPair(cpu1: *second_core.Second, rounds: usize) !void {
    var cpu0 = try pair(cpu1);
    defer cpu0.close();
    try cpu0.writeWord(memmap.sram_base + 0x1000, 0xBF00_BF00);
    try cpu0.writeWord(memmap.sram_base + 0x1004, 0xE7FC_BF00);
    try cpu1.core.writeWord(memmap.sram_base + 0x2000, 0x2007_BF20);
    try cpu1.core.writeWord(memmap.sram_base + 0x2004, 0xE7FE_E7FE);
    cpu1.pc = memmap.sram_base + 0x2000;
    _ = try mod.interleave(cpu0, memmap.sram_base + 0x1000, rounds * second_core.limits.round, .{}, cpu1);
}

test "a CPU1 in WFE with no event parks and its turns still pass time" {
    var cpu1: second_core.Second = undefined;
    try parkedPair(&cpu1, 4);
    defer cpu1.close();
    try std.testing.expect(cpu1.fault == null);
    try std.testing.expectEqual(@as(usize, 1), cpu1.wait.parks);
    try std.testing.expect(cpu1.wait.parked());
    try std.testing.expectEqual(@as(u32, 0), try cpu1.core.register(.r0));
    try std.testing.expectEqual(@as(usize, 4), cpu1.turns);
    try std.testing.expect(cpu1.timebase.elapsed >= 3 * second_core.limits.round);
}

test "a parked CPU1 wakes on its own and carries on past the WFE" {
    var cpu1: second_core.Second = undefined;
    try parkedPair(&cpu1, second_core.parking.limits.spurious_after + 3);
    defer cpu1.close();
    try std.testing.expect(cpu1.fault == null);
    try std.testing.expectEqual(@as(usize, 1), cpu1.wait.wakes.spurious);
    try std.testing.expectEqual(@as(u32, 7), try cpu1.core.register(.r0));
}
