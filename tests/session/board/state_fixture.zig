//! Strict guest-state restoration, including CPU1 and late failures.
const std = @import("std");
const ra8 = @import("ra8");
const snap = ra8.session.board.state;
const file = ra8.snapshot.file;
const memmap = ra8.chip.core.memmap;
const GuestBus = ra8.chip.core.cpu.memory.guest.bus.GuestBus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Store = ra8.chip.core.cpu.memory.store.Store;
const at = memmap.sram_base + 0x400;

pub const Rig = struct {
    store: Store,
    board: ra8.board.board.Board,
    pair: ra8.chip.core.second.core.zig.run.Driver,
    bus0: GuestBus,
    bus1: GuestBus,
    cpu: Cpu,
    machines: [2]ra8.session.stop_machine.Machine,
    drivers: [2]ra8.session.step_hook.Driver,
    watches: [2]ra8.session.watch.bus.WatchBus,
    session: ra8.session.api.Session,
    edge: ra8.session.board.boundary.BoardBoundary,
    files: snap.Files,

    pub fn create() !*Rig {
        const rig = try std.testing.allocator.create(Rig);
        errdefer std.testing.allocator.destroy(rig);
        rig.store = try Store.init(null);
        errdefer rig.store.deinit();
        rig.board = ra8.board.board.Board.init(std.testing.allocator);
        errdefer rig.board.deinit();
        const guest = ra8.chip.core.cpu.memory.guest.Guest{ .store = &rig.store };
        try ra8.board.wiring.attachBlocks(&rig.board, guest);
        try ra8.board.wiring.primeWindows(&rig.board, guest, ra8.board.wiring.cpu0Windows(&rig.board));
        rig.pair = .{ .second = .{}, .core = undefined, .ns_timebase = .{}, .store = try Store.init(&rig.store), .wiring = null };
        errdefer rig.pair.store.?.deinit();
        rig.bus0 = GuestBus.of(&.{ .store = &rig.store }, false);
        rig.bus1 = GuestBus.of(&.{ .store = &rig.pair.store.? }, false);
        rig.cpu = .{ .bus = rig.bus0.view() };
        rig.pair.core = .{ .memory = .{ .store = &rig.pair.store.? }, .board = undefined, .cpu = .{ .bus = rig.bus1.view() } };
        rig.machines = @splat(.{});
        for (&rig.drivers, &rig.machines, 0..) |*driver, *machine, index| {
            driver.* = .{ .machine = machine };
            rig.watches[index] = .{ .inner = if (index == 0) rig.cpu.bus else rig.pair.core.cpu.bus, .driver = driver };
        }
        rig.session = .{ .live = .{
            .core = .{ .cpu = &rig.cpu },
            .machine = &rig.machines[0],
            .budget = 100,
            .watch = &rig.watches[0],
            .other = .{ .core = .{ .cpu = &rig.pair.core.cpu }, .machine = &rig.machines[1], .watch = &rig.watches[1] },
        } };
        rig.edge = .{ .board = &rig.board, .core = .{ .store = &rig.store }, .cpu = &rig.cpu, .second = &rig.pair.second, .second_memory = rig.pair.guest() };
        rig.files = .{ .store = &rig.store, .cpu = &rig.cpu, .board = &rig.board, .edge = &rig.edge, .session = &rig.session, .pair = &rig.pair, .image = "same immutable ELF" };
        return rig;
    }

    pub fn destroy(self: *Rig) void {
        self.pair.store.?.deinit();
        self.board.deinit();
        self.store.deinit();
        std.testing.allocator.destroy(self);
    }

    pub fn save(self: *Rig) !std.Io.Writer.Allocating {
        var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
        errdefer writer.deinit();
        try self.files.writeTo(&writer.writer);
        return writer;
    }
};

pub fn populated(rig: *Rig) !void {
    @memcpy(rig.store.span(at, 2).?, &[_]u8{ 0x01, 0x20 }); // MOVS r0,#1
    rig.cpu.regs.pc = at;
    rig.cpu.regs.xpsr = ra8.chip.core.cpu.regs.xpsr_bits.thumb;
    rig.cpu.exclusive = at + 4;
    rig.cpu.event = true;
    rig.cpu.retired = 117;
    rig.cpu.slots = 121;
    rig.cpu.sync_entries = 4;
    rig.cpu.booted = true;
    rig.cpu.banked.current = .non_secure;
    @memcpy(rig.pair.store.?.span(memmap.mram_base + 0x1000, 4).?, &[_]u8{ 1, 2, 3, 4 });
    @memcpy(rig.pair.store.?.span(memmap.ppb_base + 0x100, 4).?, &[_]u8{ 5, 6, 7, 8 });
    rig.pair.core.cpu.regs.low[4] = 0xabcdef;
    rig.pair.core.cpu.exclusive = memmap.mram_base + 4;
    rig.pair.core.cpu.retired = 200;
    rig.pair.core.cpu.slots = 209;
    rig.pair.core.cpu.sync_entries = 9;
    rig.pair.core.cpu.booted = true;
    rig.pair.second.state.held = true;
    rig.pair.second.state.unvectored = true;
    rig.pair.second.state.resets_seen = 7;
    rig.pair.second.guard.latch = .{};
    rig.pair.second.state.timebase.ticks = 123;
    rig.pair.cycle_remainder = 9;
    rig.pair.last_ran = 27;
    rig.machines[0].fpb.enabled = true;
    rig.machines[0].fpb.comps[0] = at | 1;
    rig.machines[1].dwt.comps[2] = at;
    rig.machines[1].monitor_pending = .watchpoint;
    rig.drivers[1].cycles = .{ .known = true, .base = 2, .ran = 3 };
    rig.session.live.started = true;
    rig.session.live.clock.count = .{ .known = true, .base = 5, .ran = 6 };
    rig.session.live.other.?.clock.count = .{ .known = true, .base = 7, .ran = 8 };
    rig.board.bus.write(0x4fff_ff00, 4, 0x55);
    _ = rig.board.bus.read(0x4fff_ff04, 4);
    try rig.board.input_script.parse("at 1s button power\n");
    rig.board.time.base.base_ns = 1_000_000_000;
    rig.board.input_script.now_ns = rig.board.time.base.now();
    rig.board.input_script.cursor = 1;
}

pub fn replacement(bytes: []const u8, kind: file.Kind, payload: []const u8) !std.Io.Writer.Allocating {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    errdefer out.deinit();
    try file.writeHeader(&out.writer);
    var reader = try file.Reader.open(bytes);
    while (try reader.next()) |section| {
        const data = if (section.kind == kind) payload else section.payload;
        try file.writeSectionHeader(&out.writer, section.kind, data.len);
        try out.writer.writeAll(data);
    }
    return out;
}

pub fn continued(opened: *ra8.session.harness.Harness, budget: usize) !void {
    if (opened.state.files.pair != null) {
        // The served API is all-stop: exercise both parked cores explicitly.
        var left = budget;
        while (left != 0) {
            const slice = @min(left, 1000);
            try runCore(opened, .cpu0, slice);
            try runCore(opened, .cpu1, slice);
            left -= slice;
        }
        try opened.session().switchTo(.cpu0);
    } else try runCore(opened, .cpu0, budget);
}
fn runCore(opened: *ra8.session.harness.Harness, core: ra8.session.api.Core, budget: usize) !void {
    try opened.session().switchTo(core);
    opened.session().live.budget = budget;
    const cpu = opened.session().live.core.cpu;
    const before = cpu.retired;
    const result = try opened.session().run(core, .cont);
    if (result != .count) {
        std.debug.print("unexpected served fixture outcome: {any}\n", .{result});
        return error.UnexpectedFixtureStop;
    }
    try std.testing.expect(cpu.retired > before);
}

pub fn sameGuest(left: *ra8.session.harness.Harness, right: *ra8.session.harness.Harness) !void {
    try sameCpu(left.primaryCpu(), right.primaryCpu());
    try sameStore(&left.state.cpu0.store.?, &right.state.cpu0.store.?);
    if (left.state.files.pair) |first| {
        const second = right.state.files.pair orelse return error.MissingCpu1;
        try sameCpu(&first.core.cpu, &second.core.cpu);
        try sameStore(&first.store.?, &second.store.?);
        try std.testing.expectEqualDeep(first.second.state.interrupts, second.second.state.interrupts);
    }
    try std.testing.expectEqualDeep(left.board().mailbox, right.board().mailbox);
    try std.testing.expectEqual(left.board().time.base.now(), right.board().time.base.now());
}
fn sameCpu(left: *Cpu, right: *Cpu) !void {
    try std.testing.expectEqualDeep(left.regs, right.regs);
    try std.testing.expectEqualDeep(left.banked, right.banked);
    try std.testing.expectEqual(left.retired, right.retired);
    try std.testing.expectEqual(left.slots, right.slots);
    try std.testing.expectEqual(left.sync_entries, right.sync_entries);
}
fn sameStore(left: *Store, right: *Store) !void {
    // Independent direct byte oracles over every private and shared fixed region.
    for (left.pages, right.pages) |a, b| {
        try std.testing.expectEqual(a != null, b != null);
        if (a) |bytes| try std.testing.expectEqualSlices(u8, bytes, b.?);
    }
}

pub fn cacheOracle(opened: *ra8.session.harness.Harness, captureFn: anytype) !void {
    const cpu = opened.primaryCpu();
    const code = memmap.sram_base + 0x400;
    try opened.guest().write(code, &.{ 0x01, 0x20, 0xFE, 0xE7 });
    cpu.regs.pc = code;
    cpu.regs.xpsr = ra8.chip.core.cpu.regs.xpsr_bits.thumb;
    cpu.regs.primask = 1;
    cpu.banked.current = .secure;
    var saved = try captureFn(opened);
    defer saved.deinit();
    try opened.guest().write(code, &.{ 0x02, 0x20 });
    const changed = try opened.session().step(.cpu0);
    try std.testing.expect(changed == .stop and changed.stop == .stepped);
    try std.testing.expectEqual(@as(u32, 2), cpu.regs.low[0]);
    try std.testing.expect(cpu.blocks.?.formed > 0);
    try opened.state.files.readFrom(saved.written());
    try std.testing.expectEqual(@as(u64, 0), cpu.blocks.?.formed);
    try std.testing.expect(cpu.blocks.?.current == null);
    const restored = try opened.session().step(.cpu0);
    try std.testing.expect(restored == .stop and restored.stop == .stepped);
    try std.testing.expectEqual(@as(u32, 1), cpu.regs.low[0]);
}
