//! Covers AM07 + AM09 memory reader/writer boundaries:
//! - `*const Store` / `*const Extra` read-only slice & tracker types
//! - >4 independent dual-core machines never interfering
//! - CPU1 private TCM/MRAM/PPB vs shared SRAM/SDRAM single-hooked joined trail
//! - Self-modifying code (`fanout`) block-cache invalidation on write & undo
//! - Per-slot + board `(r, .board, 1)` / R-gap DMA watches & MMIO touched-section redo
const std = @import("std");
const ra8 = @import("ra8");
const memmap = ra8.chip.core.memmap;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const regs_mod = ra8.chip.core.cpu.regs;
const decode = ra8.chip.core.cpu.decode;
const BlockCache = decode.block_cache.BlockCache;
const Store = ra8.chip.core.cpu.memory.store.Store;
const extra = ra8.chip.core.cpu.memory.extra;
const Tracker = @FieldType(Store, "touched");
const Initiator = ra8.chip.core.cpu.memory.initiator.Initiator;
const MemoryBus = ra8.chip.core.cpu.memory.memory_bus.MemoryBus;
const Guest = ra8.chip.core.cpu.memory.guest.Guest;
const BoardBus = ra8.chip.core.cpu.board_bus.BoardBus;
const GuestBus = @FieldType(BoardBus, "memory");
const registry = ra8.chip.periph.registry;
const Position = ra8.chip.core.scheduler.Position;
const trail_mod = ra8.session.history_trail;
const rw = ra8.session.history_reverse_watch;
const ShadowOracle = ra8.session.history_shadow_oracle.ShadowOracle;

test "const Store and const Extra expose only read-only slices and const Tracker" {
    var store = try Store.init(null);
    defer store.deinit();
    try store.map(0x02C1_E000, 0x1000);

    const cstore: *const Store = &store;
    const cextra: *const extra.Extra = &store.extra;
    comptime {
        std.debug.assert(@TypeOf(cstore.locate(0, 4).?.bytes) == []const u8);
        std.debug.assert(@TypeOf(cstore.span(0, 4).?) == []const u8);
        std.debug.assert(@TypeOf(cstore.region(0).?) == []const u8);
        std.debug.assert(@TypeOf(cstore.touches()) == *const Tracker);
        std.debug.assert(@TypeOf(cextra.locate(0, 4).?.bytes) == []const u8);
        std.debug.assert(@TypeOf(store.locateMut(0, 4).?.bytes) == []u8);
        std.debug.assert(@TypeOf(store.touchesMut()) == *Tracker);
        std.debug.assert(@TypeOf(store.extra.locateMut(0, 4).?.bytes) == []u8);
    }

    try std.testing.expectEqual(memmap.sram_base, cstore.locate(memmap.ns_sram_base + 8, 4).?.base);
    try std.testing.expectEqual(@as(u32, 0x02C1_E000), cextra.locate(0x02C1_E010, 4).?.base);
    try std.testing.expect(cstore.touches().valid);
}

test "six independent dual-core machines record, invalidate and undo without cross-talk" {
    const count = 6;
    var cpu0: [count]Store = undefined;
    var cpu1: [count]Store = undefined;
    var slots: [count][2]u64 = @splat(.{ 0, 0 });
    var recs: [count]trail_mod.Recording = undefined;
    var caches: [count]decode.code_lines.CodeLines = undefined;
    for (0..count) |i| {
        cpu0[i] = try Store.init(null);
        cpu1[i] = try Store.init(&cpu0[i]);
        recs[i] = trail_mod.Recording.init(std.testing.allocator, .{ &slots[i][0], &slots[i][1] }, &cpu0[i]);
        recs[i].arm();
        caches[i].clear();
        caches[i].mark(memmap.sram_base + 0x80, memmap.sram_base + 0x90);
        try cpu0[i].fanMut().attach(&caches[i]);
    }
    defer for (0..count) |i| {
        cpu0[i].fanMut().detach(&caches[i]);
        recs[i].deinit();
        cpu1[i].deinit();
        cpu0[i].deinit();
    };

    try (Guest{ .store = &cpu0[2], .initiator = .cpu0 }).write(memmap.sram_base + 0x84, &.{0xA2});
    try (Guest{ .store = &cpu1[4], .initiator = .cpu1 }).write(memmap.ns_sram_base + 0x84, &.{0xB4});
    for (0..count) |i| {
        const expected_records: usize = if (i == 2 or i == 4) 1 else 0;
        try std.testing.expectEqual(expected_records, recs[i].record_count);
        try std.testing.expectEqual(i != 2 and i != 4, caches[i].marked(memmap.sram_base + 0x80));
        const expected_byte: u8 = if (i == 2) 0xA2 else if (i == 4) 0xB4 else 0;
        try std.testing.expectEqual(expected_byte, cpu0[i].span(memmap.sram_base + 0x84, 1).?[0]);
    }
}

test "CPU1 private MRAM/TCM/PPB vs shared SRAM/SDRAM hooks once on joined trail" {
    var first = try Store.init(null);
    defer first.deinit();
    var second = try Store.init(&first);
    defer second.deinit();

    var slots: [2]u64 = .{ 10, 20 };
    var rec = trail_mod.Recording.init(std.testing.allocator, .{ &slots[0], &slots[1] }, &first);
    defer rec.deinit();
    rec.arm();

    var oracle0 = ShadowOracle.init(std.testing.allocator);
    defer oracle0.deinit();
    try oracle0.trackStore(&first);

    // Private writes on CPU1 feed the joined trail once while leaving CPU0's private pages clean.
    try second.write(.cpu1, memmap.mram_base + 0x40, &.{0x11});
    try second.write(.cpu1, memmap.dtcm_base + 0x20, &.{0x22});
    try second.write(.cpu1, memmap.ppb_base + 0x10, &.{0x33});
    try std.testing.expectEqual(@as(usize, 3), rec.record_count);
    try std.testing.expectEqual(@as(u8, 0), first.span(memmap.mram_base + 0x40, 1).?[0]);
    try std.testing.expectEqual(@as(u8, 0), first.span(memmap.dtcm_base + 0x20, 1).?[0]);
    try std.testing.expectEqual(@as(u8, 0), first.span(memmap.ppb_base + 0x10, 1).?[0]);

    // Shared SRAM and SDRAM writes via NS aliases fold to canonical bases and hook exactly once.
    try second.write(.cpu1, memmap.ns_sram_base + 0x100, &.{ 0xDE, 0xAD });
    try second.write(.cpu1, memmap.ns_sdram_base + 0x200, &.{ 0xBE, 0xEF });
    try std.testing.expectEqual(@as(usize, 5), rec.record_count);
    try std.testing.expectEqual(memmap.sram_base, rec.slice()[3].bytes.base);
    try std.testing.expectEqual(Initiator.cpu1, rec.slice()[3].bytes.initiator);
    try std.testing.expectEqual(@as(u64, 20), rec.slice()[3].bytes.source.core.slots);
    try std.testing.expectEqual(memmap.sdram_base, rec.slice()[4].bytes.base);
    try std.testing.expectEqualSlices(u8, &.{ 0xDE, 0xAD }, first.span(memmap.sram_base + 0x100, 2).?);
    try std.testing.expectEqualSlices(u8, &.{ 0xBE, 0xEF }, first.span(memmap.sdram_base + 0x200, 2).?);
    try oracle0.verifyRecording(rec.slice()[3..5]);
}

test "self-modifying code invalidates BlockCache on CPU write and on undo rawWrite" {
    var first = try Store.init(null);
    defer first.deinit();
    var second = try Store.init(&first);
    defer second.deinit();

    const cache = try std.testing.allocator.create(BlockCache);
    defer std.testing.allocator.destroy(cache);
    cache.init();
    try first.fanMut().attach(&cache.lines);
    defer first.fanMut().detach(&cache.lines);

    const block_at = memmap.sram_base + 0x300;
    // movs r0, #1 (0x2001); movs r1, #2 (0x2102); nop (0xBF00)
    try first.rawWrite(block_at, &.{ 0x01, 0x20, 0x02, 0x21, 0x00, 0xBF });

    var slots: [2]u64 = .{ 1, 1 };
    var rec = trail_mod.Recording.init(std.testing.allocator, .{ &slots[0], &slots[1] }, &first);
    defer rec.deinit();
    rec.arm();

    var mem_bus = MemoryBus{ .store = &first, .initiator = .cpu0, .fast_enabled = true };
    var cpu: Cpu = .{ .bus = mem_bus.view(), .blocks = cache };
    cpu.regs.xpsr = regs_mod.xpsr_bits.thumb;
    cpu.regs.pc = block_at;
    try std.testing.expectEqual(.count, std.meta.activeTag(cpu.run(3)));
    try std.testing.expectEqual(@as(u32, 2), cpu.regs.get(1));
    try std.testing.expectEqual(@as(u64, 1), cache.formed);

    // CPU1 overwrites instruction 2 via NS alias with `movs r1, #9` (0x2109).
    try (Guest{ .store = &second, .initiator = .cpu1 }).write(memmap.ns_sram_base + 0x302, &.{ 0x09, 0x21 });
    cpu.regs.pc = block_at;
    try std.testing.expectEqual(.count, std.meta.activeTag(cpu.run(3)));
    try std.testing.expectEqual(@as(u64, 1), cache.dropped);
    try std.testing.expectEqual(@as(u32, 9), cpu.regs.get(1));

    // Undo restores 0x2102 via rawWrite and drops the block again so r1 returns to 2.
    _ = try rec.undo();
    cpu.regs.pc = block_at;
    try std.testing.expectEqual(.count, std.meta.activeTag(cpu.run(3)));
    try std.testing.expectEqual(@as(u64, 2), cache.dropped);
    try std.testing.expectEqual(@as(u32, 2), cpu.regs.get(1));
}

const TouchCapture = struct {
    addr: u32 = 0,
    writes: usize = 0,
    reads: usize = 0,

    fn note(ctx: *anyopaque, address: u32, is_write: bool) void {
        const self: *TouchCapture = @ptrCast(@alignCast(ctx));
        self.addr = address;
        if (is_write) self.writes += 1 else self.reads += 1;
    }
};

const ScriptedWatch = struct {
    writes: []const rw.Write,

    fn replay(ctx: *anyopaque, base: rw.Checkpoint, _: Position, range: rw.Range, sink: *rw.Sink) rw.Error!void {
        const self: *ScriptedWatch = @ptrCast(@alignCast(ctx));
        for (self.writes) |w| {
            const ord = Position.order(w.position, base.position) orelse continue;
            if (ord != .lt and range.overlaps(w.address, w.len)) sink.report(w);
        }
    }

    fn cancelled(_: *anyopaque) bool {
        return false;
    }
};

test "per-slot CPU writes, board (r,board,1) + R-gap DMA watches and MMIO touched hook" {
    var store = try Store.init(null);
    defer store.deinit();
    var slots: [2]u64 = .{ 4, 6 };
    var rec = trail_mod.Recording.init(std.testing.allocator, .{ &slots[0], &slots[1] }, &store);
    defer rec.deinit();
    rec.arm();
    const target = memmap.sram_base + 0x500;
    try rec.watch(target, 4, "dma_buf");

    // Per-slot CPU writes record core slots without firing board watch hits.
    try store.write(.cpu0, target, &.{ 1, 0, 0, 0 });
    try store.write(.cpu1, target, &.{ 2, 0, 0, 0 });
    try std.testing.expectEqual(@as(usize, 0), rec.hitSlice().len);
    // Board DMA write records Source.board(.dmac) AND raises a labelled watch hit.
    try store.write(.dmac, target, &.{ 9, 0, 0, 0 });
    try std.testing.expectEqual(@as(usize, 1), rec.hitSlice().len);
    try std.testing.expectEqual(Initiator.dmac, rec.hitSlice()[0].source.board);
    try std.testing.expectEqualStrings("dma_buf", rec.watchSlice()[rec.hitSlice()[0].watch].label);

    // Verify (r, .board, 1) and R-gap ordering in reverse_watch search.
    const scripted = [_]rw.Write{
        .{ .position = .{ .r = 12, .phase = .cpu0, .o = 4 }, .address = target, .len = 4, .initiator = .cpu0, .source = .{ .core = .{ .core = .cpu0, .slots = 4 } }, .changed = true },
        .{ .position = .{ .r = 12, .phase = .board, .o = 1, .gap = .retired }, .address = target, .len = 4, .initiator = .dmac, .source = .{ .board = .dmac }, .changed = true },
        .{ .position = .{ .r = 12, .phase = .board, .o = 1, .gap = .polled }, .address = target, .len = 4, .initiator = .ethos_u55, .source = .{ .board = .ethos_u55 }, .changed = true },
    };
    var sw: ScriptedWatch = .{ .writes = &scripted };
    const cps = [_]rw.Checkpoint{.{ .position = .{ .r = 0 }, .id = 0 }};
    const port: rw.Port = .{ .context = &sw, .replay = ScriptedWatch.replay, .cancelled = ScriptedWatch.cancelled };
    const before_polled = try rw.search(std.testing.allocator, port, .{ .range = .{ .address = target, .size = 4 }, .from = .{ .r = 12, .phase = .board, .o = 1, .gap = .polled } }, &cps);
    try std.testing.expectEqual(Initiator.dmac, before_polled.outcome.hit.initiator);
    const after_round = try rw.search(std.testing.allocator, port, .{ .range = .{ .address = target, .size = 4 }, .from = .{ .r = 13 } }, &cps);
    try std.testing.expectEqual(Initiator.ethos_u55, after_round.outcome.hit.initiator);

    // Verify BoardBus peripheral MMIO access fires TouchedHook (marking complex redo slots).
    var periph = registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    var cap: TouchCapture = .{};
    var bb = BoardBus{
        .memory = GuestBus{ .store = .{ .store = &store, .initiator = .cpu0 } },
        .periph = &periph,
        .touched = .{ .context = &cap, .touchFn = TouchCapture.note },
    };
    const view = bb.view();
    var read_buf: [4]u8 = undefined;
    _ = view.write(registry.base + 0x100, &.{ 1, 2, 3, 4 }) catch {};
    _ = view.read(registry.base + 0x100, &read_buf) catch {};
    try std.testing.expectEqual(@as(usize, 1), cap.writes);
    try std.testing.expectEqual(@as(usize, 1), cap.reads);
    try std.testing.expectEqual(registry.base + 0x100, cap.addr);
}
