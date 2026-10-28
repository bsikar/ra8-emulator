//! Reverse-continue with a watchpoint armed: the search is no longer
//! refused, and it lands exactly on the stop the watch raised going
//! forward, the latest one before the cursor.
const std = @import("std");
const ra8 = @import("ra8");
const transport = ra8.session.transport;
const fakes = @import("../history_fakes.zig");
const position_mod = ra8.session.history_position;
const rig = @import("transport_rig.zig");

const history_elf = "tests/fixtures/dfu/dfu_bootloader.elf";

fn pumpDone(t: *transport.Transport, fake: *rig.FakeWall) !transport.Finished {
    var pumped = try t.pump(fake.wall(), fake.now_ns + 4_000_000);
    var rounds: usize = 0;
    while (pumped.finished == null) : (rounds += 1) {
        try std.testing.expect(rounds < 1_000_000);
        pumped = try t.pump(fake.wall(), fake.now_ns + 4_000_000);
    }
    return pumped.finished.?;
}

const watched_addr = ra8.chip.core.memmap.sram_base + 0x6200;
const source_addr = ra8.chip.core.memmap.sram_base + 0x6300;

fn setupMultiInitiatorFixture(opened: *ra8.session.harness.Harness) !void {
    opened.state.edge.idle_skip = false;
    opened.state.edge.timebase.per_chunk = 32;
    opened.session().live.boundary.?.chunk = 32;
    const at = ra8.chip.core.memmap.sram_base + 0x6000;
    var code: [128]u8 = undefined;
    // 32 NOPs so round 0 completes and round 1 opens with checkpoint 1
    var i: usize = 0;
    while (i < 64) : (i += 2) {
        code[i] = 0x00;
        code[i + 1] = 0xBF;
    }
    const ops = [_]u8{
        0x11, 0x20, // movs r0, #0x11
        0x08, 0x60, // str r0, [r1, #0] (CPU store)
        0x08, 0x60, // str r0, [r1, #0] (Same-bytes store)
        0x01, 0x25, // movs r5, #1
        0x25, 0x70, // strb r5, [r4, #0] (DMAST = 1)
        0x1a, 0x60, // str r2, [r3, #0] (DMSAR = source)
        0x59, 0x60, // str r1, [r3, #4] (DMDAR = watched_addr)
        0x04, 0x25, // movs r5, #4
        0x9d, 0x60, // str r5, [r3, #8] (DMCRA = 4)
        0x00, 0x25, // movs r5, #0
        0x1d, 0x82, // strh r5, [r3, #0x10] (DMTMD = 0)
        0x9d, 0x82, // strh r5, [r3, #0x14] (DMAMD = 0)
        0x01, 0x25, // movs r5, #1
        0x1d, 0x77, // strb r5, [r3, #0x1C] (DMCNT = 1)
        0x5d, 0x77, // strb r5, [r3, #0x1D] (DMREQ = 1: triggers DMAC)
        0x33, 0x20, // movs r0, #0x33
        0x08, 0x60, // str r0, [r1, #0] (CPU store)
        0xfe, 0xe7, // b .
    };
    @memcpy(code[64 .. 64 + ops.len], &ops);
    try opened.guest().write(at, code[0 .. 64 + ops.len]);
    try opened.guest().writeWord(watched_addr, 0);
    try opened.guest().writeWord(source_addr, 0x2222_2222);
    const cpu = opened.primaryCpu();
    cpu.regs.low[0] = 0;
    cpu.regs.low[1] = watched_addr;
    cpu.regs.low[2] = source_addr;
    cpu.regs.low[3] = 0x4000_A000;
    cpu.regs.low[4] = 0x4000_A800;
    cpu.regs.pc = at;
    cpu.regs.primask = 1;
    cpu.waiting = null;
}

const ForwardCollector = struct {
    writes: [16]position_mod.Position = undefined,
    initiators: [16]ra8.chip.core.cpu.memory.initiator.Initiator = undefined,
    count: usize = 0,
    range: ra8.session.history_reverse_watch.Range,
    session: *ra8.session.api.Session,

    fn onBytes(ctx: *anyopaque, write: ra8.chip.core.cpu.memory.observer.Write) void {
        const self: *ForwardCollector = @ptrCast(@alignCast(ctx));
        const start: u64 = @as(u64, write.base) + write.offset;
        const len: u32 = @intCast(write.pre.len);
        if (!self.range.overlaps(@truncate(start), len)) return;
        const grid = self.session.grid orelse return;
        const cpu0 = self.session.live.core.cpu;
        const cpu1 = if (self.session.live.other) |o| o.core.cpu else null;
        const phase: position_mod.Phase = grid.at.phase;
        const o: u32 = switch (phase) {
            .cpu0 => if (cpu0.slots >= grid.base[0]) @intCast(cpu0.slots - grid.base[0] + 1) else 1,
            .cpu1 => if (cpu1 != null and cpu1.?.slots >= grid.base[1]) @intCast(cpu1.?.slots - grid.base[1] + 1) else 1,
            .board => 0,
        };
        if (self.count < self.writes.len) {
            self.writes[self.count] = .{
                .branch = grid.at.branch,
                .r = grid.at.r,
                .phase = phase,
                .o = o,
                .gap = .retired,
            };
            self.initiators[self.count] = write.initiator;
            self.count += 1;
        }
    }

    fn onBarrier(_: *anyopaque, _: ra8.chip.core.cpu.memory.observer.Barrier) void {}

    pub fn observer(self: *ForwardCollector) ra8.chip.core.cpu.memory.observer.Observer {
        return .{ .ctx = self, .vtable = &.{ .bytes = onBytes, .barrier = onBarrier } };
    }
};

test "multi-initiator writes match forward scan on reverse-continue" {
    const gpa = std.testing.allocator;
    var sink: fakes.Sink = .{ .gpa = gpa };
    defer sink.deinit();
    var objects: fakes.Objects = .{ .gpa = gpa };
    defer objects.deinit();
    var opened = try ra8.session.harness.open(gpa, std.testing.io, .{
        .elf_path = history_elf,
        .checkpoint_every = 1,
        .history_storage = sink.storage(),
        .history_objects = objects.objects(),
    });
    defer opened.deinit();
    const session = opened.session();
    try setupMultiInitiatorFixture(&opened);
    try session.setRunBudget(.cpu0, 128);

    var collector = ForwardCollector{
        .range = .{ .address = watched_addr, .size = 4 },
        .session = session,
    };
    const obs = collector.observer();
    const store = session.store().?;
    store.observer = &obs;

    _ = try session.run(.cpu0, .run);
    while (true) {
        const ended = try session.run(.cpu0, .cont);
        if (ended == .count) break;
    }
    store.observer = null;

    var had_cpu = false;
    var had_dmac = false;
    for (collector.initiators[0..collector.count]) |init| {
        if (init == .cpu0) had_cpu = true;
        if (init == .dmac) had_dmac = true;
    }
    try std.testing.expect(had_cpu);
    try std.testing.expect(had_dmac);
    try std.testing.expect(collector.count >= 4);

    // Sort forward writes into position order
    var sorted_writes: [16]position_mod.Position = undefined;
    @memcpy(sorted_writes[0..collector.count], collector.writes[0..collector.count]);
    var a_idx: usize = 0;
    while (a_idx < collector.count) : (a_idx += 1) {
        var b_idx = a_idx + 1;
        while (b_idx < collector.count) : (b_idx += 1) {
            const ord = try position_mod.compare(sorted_writes[a_idx], sorted_writes[b_idx]);
            if (ord == .gt) {
                const tmp = sorted_writes[a_idx];
                sorted_writes[a_idx] = sorted_writes[b_idx];
                sorted_writes[b_idx] = tmp;
            }
        }
    }

    _ = try session.setWatchpoint(.cpu0, .{
        .first = watched_addr,
        .last = watched_addr + 3,
        .kind = .write,
    });

    var state = rig.TestBridge{ .gpa = gpa, .opened = &opened, .sink = &sink, .objects = &objects };
    defer state.deinit();
    var t = transport.Transport{ .session = session };
    t.history = state.bridge();
    var fake = rig.FakeWall{};

    var rev_idx: usize = collector.count;
    while (rev_idx > 0) {
        rev_idx -= 1;
        const expected_pos = sorted_writes[rev_idx];
        const ticket = try t.command(.rcont);
        const finished = try pumpDone(&t, &fake);
        try std.testing.expectEqual(ticket, finished.ticket);
        try std.testing.expectEqualStrings("watchpoint", @tagName(finished.ended.stop));
        // Finding 1 & 5: Landing must be exact at (r, phase, o), never overshooting.
        // Persistent history is single-core (Error.SecondCore), running CPU0 and board phase.
        try std.testing.expectEqual(expected_pos.r, session.grid.?.at.r);
        try std.testing.expectEqual(expected_pos.phase, session.grid.?.at.phase);
        try std.testing.expectEqual(expected_pos.o, session.grid.?.at.o);
        try std.testing.expect((try position_mod.compare(session.grid.?.at, expected_pos)) == .eq);
    }

    // After all writes have been visited backward, the next reverse-continue
    // settles with history_start.
    const start_ticket = try t.command(.rcont);
    const start_finished = try pumpDone(&t, &fake);
    try std.testing.expectEqual(start_ticket, start_finished.ticket);
    try std.testing.expectEqualStrings("history_start", @tagName(start_finished.ended.stop));
}

test "reverse-continue with watchpoint propagates Error.Cancelled when cancelled" {
    const gpa = std.testing.allocator;
    var sink: fakes.Sink = .{ .gpa = gpa };
    defer sink.deinit();
    var objects: fakes.Objects = .{ .gpa = gpa };
    defer objects.deinit();
    var opened = try ra8.session.harness.open(gpa, std.testing.io, .{
        .elf_path = history_elf,
        .checkpoint_every = 1,
        .history_storage = sink.storage(),
        .history_objects = objects.objects(),
    });
    defer opened.deinit();
    const session = opened.session();
    try setupMultiInitiatorFixture(&opened);
    try session.setRunBudget(.cpu0, 128);

    _ = try session.run(.cpu0, .run);
    while (true) {
        const ended = try session.run(.cpu0, .cont);
        if (ended == .count) break;
    }

    _ = try session.setWatchpoint(.cpu0, .{
        .first = watched_addr,
        .last = watched_addr + 3,
        .kind = .write,
    });

    var state = rig.TestBridge{ .gpa = gpa, .opened = &opened, .sink = &sink, .objects = &objects };
    defer state.deinit();
    var t = transport.Transport{ .session = session };
    t.history = state.bridge();
    var fake = rig.FakeWall{};

    _ = try t.command(.rcont);
    // Explicitly cancel the transport search
    t.cancelled = true;

    // Must propagate Error.Cancelled, never Error.HistoryBroken
    try std.testing.expectError(error.Cancelled, t.pump(fake.wall(), fake.now_ns + 4_000_000));
}

test "reverse-continue watchpoint search spans multiple slices and lands exactly" {
    const gpa = std.testing.allocator;
    var sink: fakes.Sink = .{ .gpa = gpa };
    defer sink.deinit();
    var objects: fakes.Objects = .{ .gpa = gpa };
    defer objects.deinit();
    var opened = try ra8.session.harness.open(gpa, std.testing.io, .{
        .elf_path = history_elf,
        .checkpoint_every = 1,
        .history_storage = sink.storage(),
        .history_objects = objects.objects(),
    });
    defer opened.deinit();
    const session = opened.session();
    try setupMultiInitiatorFixture(&opened);
    try session.setRunBudget(.cpu0, 128);

    var collector = ForwardCollector{
        .range = .{ .address = watched_addr, .size = 4 },
        .session = session,
    };
    const obs = collector.observer();
    const store = session.store().?;
    store.observer = &obs;

    _ = try session.run(.cpu0, .run);
    while (true) {
        const ended = try session.run(.cpu0, .cont);
        if (ended == .count) break;
    }
    store.observer = null;

    _ = try session.setWatchpoint(.cpu0, .{
        .first = watched_addr,
        .last = watched_addr + 3,
        .kind = .write,
    });

    var state = rig.TestBridge{ .gpa = gpa, .opened = &opened, .sink = &sink, .objects = &objects };
    defer state.deinit();
    var t = transport.Transport{ .session = session };
    t.history = state.bridge();
    var fake = rig.FakeWall{};

    const expected_pos = collector.writes[collector.count - 1];
    const ticket = try t.command(.rcont);

    // Call pump with deadline so each pump executes only 1 slice before deadline check
    var pump_count: usize = 0;
    var finished: ?transport.Finished = null;
    while (finished == null) : (pump_count += 1) {
        try std.testing.expect(pump_count < 100);
        const pumped = try t.pump(fake.wall(), fake.now_ns + 1_500_000);
        finished = pumped.finished;
    }

    // Must have spanned several slices (> 1) across the checkpoint intervals
    try std.testing.expect(pump_count > 1);
    try std.testing.expectEqual(ticket, finished.?.ticket);
    try std.testing.expectEqualStrings("watchpoint", @tagName(finished.?.ended.stop));
    // And lands exactly at (r, phase, o) without overshooting
    try std.testing.expectEqual(expected_pos.r, session.grid.?.at.r);
    try std.testing.expectEqual(expected_pos.phase, session.grid.?.at.phase);
    try std.testing.expectEqual(expected_pos.o, session.grid.?.at.o);
    try std.testing.expect((try position_mod.compare(session.grid.?.at, expected_pos)) == .eq);
}

test "reopened history loads touched-page records from persisted storage" {
    const gpa = std.testing.allocator;
    var sink: fakes.Sink = .{ .gpa = gpa };
    defer sink.deinit();
    var objects: fakes.Objects = .{ .gpa = gpa };
    defer objects.deinit();

    var opened = try ra8.session.harness.open(gpa, std.testing.io, .{
        .elf_path = history_elf,
        .checkpoint_every = 1,
        .history_storage = sink.storage(),
        .history_objects = objects.objects(),
    });
    defer opened.deinit();
    const session = opened.session();
    _ = try session.run(.cpu0, .run);

    var state = rig.TestBridge{ .gpa = gpa, .opened = &opened, .sink = &sink, .objects = &objects };
    defer state.deinit();
    const b = state.bridge();
    const facts = try b.facts(b.context);
    try std.testing.expect(facts.checkpoints.len >= 2);

    var has_touched = false;
    for (facts.checkpoints) |cp| {
        if (cp.touched != null) has_touched = true;
    }
    try std.testing.expect(has_touched);
}
