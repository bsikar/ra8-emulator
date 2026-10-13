//! Strict oracles for the saved round over the real ThreadX and dual IPC corpus.
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("../board/state_fixture.zig");
const Harness = ra8.session.harness.Harness;
const Cpu1 = ra8.session.cpu1.bringup.Cpu1;
const Clock = ra8.session.run.loop.Clock;
const scheduler = ra8.chip.core.scheduler;
const Case = struct { cpu0: []const u8, cpu1: ?[]const u8 = null };
const cases = [_]Case{
    .{ .cpu0 = "tests/fixtures/threadx/threadx_stkof.elf" },
    .{ .cpu0 = "tests/fixtures/trustzone/cpu1_pingpong_ipc.elf", .cpu1 = "tests/fixtures/trustzone/cpu1_pingpong_ipc_cpu1.elf" },
};

fn open(case: Case, second: *Cpu1) !Harness {
    var harness = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = case.cpu0, .history_frames = 2 });
    errdefer harness.deinit();
    if (case.cpu1) |path| try second.open(std.testing.allocator, std.testing.io, &harness, path);
    harness.state.edge.idle_skip = false;
    return harness;
}

fn run(harness: *Harness, budget: u64) !void {
    try harness.session().setRunBudget(.cpu0, budget);
    const ended = try harness.session().run(.cpu0, .cont);
    if (ended != .count) {
        std.debug.print("grid unexpected outcome: {any}\n", .{ended});
        return error.UnexpectedStop;
    }
}

fn capture(harness: *Harness) !std.Io.Writer.Allocating {
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    errdefer writer.deinit();
    try harness.state.files.writeTo(&writer.writer);
    return writer;
}

fn same(a: *Harness, b: *Harness) !void {
    try fixture.sameGuest(a, b);
    try std.testing.expectEqualDeep(a.state.edge.saved, b.state.edge.saved);
    try std.testing.expectEqualDeep(a.state.edge.timebase, b.state.edge.timebase);
    if (a.state.files.pair) |pair| {
        const other = b.state.files.pair.?;
        try std.testing.expectEqualDeep(pair.turn_state, other.turn_state);
        try std.testing.expectEqual(pair.second.state.turns, other.second.state.turns);
        try std.testing.expectEqual(pair.second.state.ran, other.second.state.ran);
        try std.testing.expectEqual(pair.cycle_remainder, other.cycle_remainder);
    }
}

test "grid strict real corpus split random budgets armed quiet pause and speed are identical" {
    for (cases) |case| {
        var a1: Cpu1 = .{};
        var a = try open(case, &a1);
        defer a.deinit();
        defer if (case.cpu1 != null) a1.close(std.testing.allocator);
        var b1: Cpu1 = .{};
        var b = try open(case, &b1);
        defer b.deinit();
        defer if (case.cpu1 != null) b1.close(std.testing.allocator);
        _ = try b.session().setBreakpoint(.cpu0, .{ .address = 0xffffff00 });
        if (case.cpu1 != null) _ = try b.session().setBreakpoint(.cpu1, .{ .address = 0xffffff00 });
        try run(&a, 125_987);
        var left: u64 = 125_987;
        var seed: u64 = 418;
        while (left != 0) {
            seed = seed *% 6364136223846793005 +% 1;
            const count = @min(left, 1 + (seed >> 32) % 13_777);
            try b.session().setSpeed(.cpu0, if (seed & 1 == 0) 0.25 else 8);
            try run(&b, count);
            const before = b.state.edge.saved;
            _ = try b.session().interrupt(.cpu0);
            try std.testing.expectEqualDeep(before, b.state.edge.saved);
            left -= count;
        }
        try same(&a, &b);
        if (case.cpu1 != null) {
            try std.testing.expect(a1.cpu().retired > 100);
            try std.testing.expect(a.board().mailbox.channels[2].pushes > 0);
            try std.testing.expect(a.board().mailbox.channels[0].pops > 0);
        }
        std.debug.print("CHECK=corpus split COMMAND=run 125987 versus seeded slices EXPECTED=identical ACTUAL={s} slots={d} round={d} RESULT=PASS\n", .{ case.cpu0, a.primaryCpu().slots, a.state.edge.saved.at.r });
    }
}

test "grid strict real corpus session and plain share intervals cuts slot time and CPU1 turns" {
    for (cases) |case| {
        var a1: Cpu1 = .{};
        var a = try open(case, &a1);
        defer a.deinit();
        defer if (case.cpu1 != null) a1.close(std.testing.allocator);
        var b1: Cpu1 = .{};
        var b = try open(case, &b1);
        defer b.deinit();
        defer if (case.cpu1 != null) b1.close(std.testing.allocator);
        var clock: Clock = .{ .io = std.testing.io, .memory = b.guest(), .board = b.board(), .timebase = &b.state.edge.timebase, .cpu1 = b.state.files.pair };
        b.state.memory.scs.cut = &b.state.edge.cut;
        b.primaryCpu().cut = &b.state.edge.cut;
        var owed: ra8.chip.core.cpu.boot.Owed = .{ .hold = true };
        for ([_]u64{ 17_719, 89_517, 18_751 }) |count| {
            try run(&a, count);
            try std.testing.expectEqual(ra8.chip.core.cpu.cpu.Stop.count, try ra8.chip.core.cpu.boot.stretches(b.primaryCpu(), count, clock.boundary(), null, &owed, null));
        }
        b.state.edge.saved = clock.saved;
        b.state.edge.ns_timebase = clock.ns_timebase;
        try same(&a, &b);
        std.debug.print("CHECK=corpus plain COMMAND=boot.stretches versus Session.run EXPECTED=identical ACTUAL={s} RESULT=PASS\n", .{case.cpu0});
    }
}

test "grid strict actual dual CPU1 partial turn restore retains pending order and divider latch" {
    var second: Cpu1 = .{};
    var live = try open(cases[1], &second);
    defer live.deinit();
    defer second.close(std.testing.allocator);
    const pc = second.cpu().regs.pc;
    const id = try live.session().setBreakpoint(.cpu1, .{ .address = pc });
    const sub = try live.session().subscribe();
    defer live.session().unsubscribe(sub);
    try live.session().setRunBudget(.cpu0, 100_000);
    const ended = try live.session().run(.cpu0, .cont);
    try std.testing.expect(ended == .stop and ended.stop == .breakpoint);
    try std.testing.expectEqual(id, ended.stop.breakpoint);
    var events: [8]ra8.session.api.Event = undefined;
    const read = live.session().pollEvents(sub, &events).?;
    var stops: u32 = 0;
    for (events[0..read.count]) |event| if (event.kind == .stopped) {
        stops += 1;
        std.debug.print("CHECK=G7 stopped core={s} selected={s}\n", .{ @tagName(event.core), @tagName(live.session().currentCore()) });
        try std.testing.expectEqual(ra8.session.api.Core.cpu1, event.core);
    };
    try std.testing.expectEqual(@as(u32, 1), stops);
    try std.testing.expectEqual(pc, second.cpu().regs.pc);
    try std.testing.expectEqual(ra8.session.api.Core.cpu0, live.session().currentCore());
    try std.testing.expect(live.primaryCpu() == live.session().live.core.cpu);
    try std.testing.expectEqual(scheduler.position.Phase.cpu1, live.state.edge.saved.at.phase);
    try std.testing.expect(second.pair.turn_state.open);
    const turn = second.pair.turn_state;
    live.board().tree.divcr2 ^= 0x20;
    second.pair.openTurn(17, 123);
    try std.testing.expectEqualDeep(turn, second.pair.turn_state);
    var saved = try capture(&live);
    defer saved.deinit();
    try live.session().clearBreakpoint(.cpu1, id);
    try run(&live, 43_219);
    var reference = try capture(&live);
    defer reference.deinit();
    try live.state.files.readFrom(saved.written());
    try std.testing.expectEqualDeep(turn, second.pair.turn_state);
    try run(&live, 43_219);
    var after = try capture(&live);
    defer after.deinit();
    try std.testing.expectEqualSlices(u8, reference.written(), after.written());
}

test "grid strict canonical targets equal every slot stepping across actual dual turns and ticks" {
    for ([_]u1{ 0, 1 }) |core| {
        var a1: Cpu1 = .{};
        var a = try open(cases[1], &a1);
        defer a.deinit();
        defer a1.close(std.testing.allocator);
        var b1: Cpu1 = .{};
        var b = try open(cases[1], &b1);
        defer b.deinit();
        defer b1.close(std.testing.allocator);
        for ([_]*Harness{ &a, &b }) |harness| {
            harness.state.edge.timebase.per_chunk = 64;
            harness.session().live.boundary.?.chunk = 64;
            harness.session().history = null;
        }
        for (0..257) |_| {
            const ended = try a.session().step(if (core == 0) .cpu0 else .cpu1);
            try std.testing.expect(ended == .stop and ended.stop == .stepped);
        }
        const ended = try b.session().live.runToCount(core, 257);
        try std.testing.expect(ended == .stop and ended.stop == .stepped);
        try same(&a, &b);
        try std.testing.expectEqual(scheduler.position.Gap.polled, a.state.edge.saved.at.gap);
        try std.testing.expect(a.state.edge.saved.at.r > 0);
        // Restoring C(k-1), then stepping, must return to the same C(k).
        var previous = try capture(&a);
        defer previous.deinit();
        _ = try a.session().step(if (core == 0) .cpu0 else .cpu1);
        var next = try capture(&a);
        defer next.deinit();
        try a.state.files.readFrom(previous.written());
        _ = try a.session().step(if (core == 0) .cpu0 else .cpu1);
        var again = try capture(&a);
        defer again.deinit();
        try std.testing.expectEqualSlices(u8, next.written(), again.written());
    }
}

test "grid strict open stretch restore and malformed scalar refusal are atomic" {
    var second: Cpu1 = .{};
    var live = try open(cases[0], &second);
    defer live.deinit();
    try run(&live, 37);
    try std.testing.expect(live.state.edge.saved.stretch.carry > 0);
    var before = try capture(&live);
    defer before.deinit();
    const grid = (try ra8.snapshot.file.Reader.find(before.written(), .grid)).?;
    var corrupt: [63]u8 = undefined;
    try std.testing.expectEqual(corrupt.len, grid.payload.len);
    @memcpy(&corrupt, grid.payload);
    corrupt[12] = 3; // Invalid phase, before any live commit.
    var bad = try fixture.replacement(before.written(), .grid, &corrupt);
    defer bad.deinit();
    try std.testing.expectError(error.BadValue, live.state.files.readFrom(bad.written()));
    var unchanged = try capture(&live);
    defer unchanged.deinit();
    try std.testing.expectEqualSlices(u8, before.written(), unchanged.written());
    try run(&live, 71_771);
    var continued = try capture(&live);
    defer continued.deinit();
    try live.state.files.readFrom(before.written());
    try run(&live, 71_771);
    var after = try capture(&live);
    defer after.deinit();
    try std.testing.expectEqualSlices(u8, continued.written(), after.written());
}

test "grid strict SysTick cut charges CPU0 slot clocks once and omits the CPU1 turn" {
    var second: Cpu1 = .{};
    var live = try open(cases[1], &second);
    defer live.deinit();
    defer second.close(std.testing.allocator);
    const map = ra8.chip.core.memmap;
    const at = map.sram_base + 0x6000;
    try live.guest().write(at, &.{ 0x01, 0x60, 0xfe, 0xe7 }); // STR r1,[r0]; B .
    const cpu = live.primaryCpu();
    cpu.regs.pc = at;
    cpu.regs.low[0] = map.syst.rvr;
    cpu.regs.low[1] = 4;
    cpu.regs.primask = 1;
    cpu.banked.current = .secure;
    cpu.waiting = null;
    try live.guest().writeWord(map.syst.csr, 5);
    try live.guest().writeWord(map.syst.rvr, 99);
    try live.guest().writeWord(0xe000_1000, 1);
    try live.guest().writeWord(0xe000_edfc, 1 << 24);
    const before0 = cpu.slots;
    const before1 = second.cpu().slots;
    const cvr = try live.guest().readWord(map.syst.cvr);
    try run(&live, 1);
    try std.testing.expectEqual(before0 + 1, cpu.slots);
    try std.testing.expectEqual(before1, second.cpu().slots);
    try std.testing.expectEqual(@as(u64, 1), live.state.edge.timebase.elapsed);
    try std.testing.expectEqual(@as(u64, 1), live.board().time.base.retired);
    try std.testing.expectEqual(@as(u32, 1), try live.guest().readWord(0xe000_1004));
    try std.testing.expectEqual(@as(u64, 1), live.state.edge.saved.at.r);
    try std.testing.expectEqual(@as(u32, 0), live.state.edge.saved.stretch.carry);
    try std.testing.expectEqual(@as(u32, 0), cvr);
    // The timer was running before the RVR store: its old reload owns this slot.
    try std.testing.expectEqual(@as(u32, 99), try live.guest().readWord(map.syst.cvr));
    try std.testing.expectEqual(@as(u64, 0), live.state.edge.timebase.ticks);
    try std.testing.expectEqual(@as(u32, 0), (try live.guest().readWord(map.syst.csr)) & (1 << 16));
}

test "grid repair G6 pre-arm carry must not count down the newly armed SysTick" {
    var second: Cpu1 = .{};
    var live = try open(cases[1], &second);
    defer live.deinit();
    defer second.close(std.testing.allocator);
    const map = ra8.chip.core.memmap;
    const at = map.sram_base + 0x6000;
    try live.guest().write(at, &.{ 0x00, 0xbf, 0x00, 0xbf, 0x00, 0xbf, 0x00, 0xbf, 0x00, 0xbf, 0x00, 0xbf, 0x01, 0x60, 0xfe, 0xe7 });
    const cpu = live.primaryCpu();
    cpu.regs.pc = at;
    cpu.regs.low[0] = map.syst.csr;
    cpu.regs.low[1] = 7;
    cpu.regs.primask = 1;
    cpu.waiting = null;
    try live.guest().writeWord(map.syst.csr, 0);
    try live.guest().writeWord(map.syst.rvr, 4);
    try live.guest().writeWord(map.syst.cvr, 0);
    try live.guest().writeWord(0xe000_1000, 1);
    try live.guest().writeWord(0xe000_edfc, 1 << 24);
    const before1 = second.cpu().slots;
    try run(&live, 7);
    try std.testing.expectEqual(@as(u64, 7), live.board().time.base.retired);
    try std.testing.expectEqual(@as(u32, 7), try live.guest().readWord(0xe000_1004));
    try std.testing.expectEqual(before1, second.cpu().slots);
    std.debug.print("CHECK=G6 CVR={d} ticks={d} pends={d}\n", .{ try live.guest().readWord(map.syst.cvr), live.state.edge.timebase.ticks, live.state.edge.timebase.pends });
    try std.testing.expectEqual(@as(u32, 0), try live.guest().readWord(map.syst.cvr));
    try std.testing.expectEqual(@as(u64, 0), live.state.edge.timebase.ticks);
    try std.testing.expectEqual(@as(u64, 0), live.state.edge.timebase.pends);
    try std.testing.expectEqual(@as(u32, 0), (try live.guest().readWord(map.syst.csr)) & (1 << 16));
    try std.testing.expectEqual(@as(u32, 0), (try live.guest().readWord(map.scb.icsr)) & (1 << 26));
}

test "grid G6 genuine pending bank and control corruption are atomic" {
    var second: Cpu1 = .{};
    var live = try open(cases[1], &second);
    defer live.deinit();
    defer second.close(std.testing.allocator);
    const map = ra8.chip.core.memmap;
    const at = map.sram_base + 0x6000;
    try live.guest().write(at, &.{ 0x00, 0xbf, 0x00, 0xbf, 0x01, 0x60, 0xfe, 0xe7 });
    const cpu = live.primaryCpu();
    cpu.regs.pc = at;
    cpu.regs.low[0] = map.syst.csr;
    cpu.regs.low[1] = 7;
    cpu.regs.primask = 1;
    cpu.waiting = null;
    try live.guest().writeWord(map.syst.csr, 0);
    try live.guest().writeWord(map.syst.rvr, 4);
    try live.guest().writeWord(map.syst.cvr, 0);
    _ = try live.session().setWatchpoint(.cpu0, .{ .first = map.syst.csr, .last = map.syst.csr + 3, .kind = .write });
    try live.session().setRunBudget(.cpu0, 3);
    const ended = try live.session().run(.cpu0, .cont);
    try std.testing.expect(ended == .stop and ended.stop == .watchpoint);
    try std.testing.expect(live.state.edge.saved.cut);
    try std.testing.expectEqual(@as(u64, 1), live.state.edge.timebase.rearms);
    try std.testing.expectEqual(@as(u64, 0), live.state.edge.ns_timebase.rearms);
    var before = try capture(&live);
    defer before.deinit();
    const grid = (try ra8.snapshot.file.Reader.find(before.written(), .grid)).?;
    try std.testing.expectEqual(@as(usize, 63), grid.payload.len);
    const offset = @intFromPtr(grid.payload.ptr) - @intFromPtr(before.written().ptr);
    try run(&live, 1);
    var reference = try capture(&live);
    defer reference.deinit();
    try live.state.files.readFrom(before.written());
    var bad = try std.testing.allocator.dupe(u8, before.written());
    defer std.testing.allocator.free(bad);
    bad[offset + 52] = 1; // Non-secure has no staged rearm.
    try std.testing.expectError(error.BadValue, live.state.files.readFrom(bad));
    bad[offset + 52] = 0;
    bad[offset + 57] = 4; // Invalid saved control bit.
    try std.testing.expectError(error.BadValue, live.state.files.readFrom(bad));
    bad[offset + 57] = 0;
    std.mem.writeInt(u32, bad[ra8.snapshot.file.magic.len..][0..4], 10, .little);
    try std.testing.expectError(error.BadVersion, live.state.files.readFrom(bad));
    var unchanged = try capture(&live);
    defer unchanged.deinit();
    try std.testing.expectEqualSlices(u8, before.written(), unchanged.written());
    try run(&live, 1);
    var future = try capture(&live);
    defer future.deinit();
    try std.testing.expectEqualSlices(u8, reference.written(), future.written());
}
