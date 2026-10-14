//! Covers src/chip/core/cpu/memory/observer.zig through the store hooks:
//! the pre-image byte writes (H1, H2), the barriers (H5), the raw restore,
//! and the per-machine fanout sharing (RA8EMU-D1).
const std = @import("std");
const ra8 = @import("ra8");
const memmap = ra8.chip.core.memmap;
const Store = ra8.chip.core.cpu.memory.store.Store;
const observer = ra8.chip.core.cpu.memory.observer;
const Initiator = ra8.chip.core.cpu.memory.initiator.Initiator;
const MemoryBus = ra8.chip.core.cpu.memory.memory_bus.MemoryBus;
const Guest = ra8.chip.core.cpu.memory.guest.Guest;
const code_lines = ra8.chip.core.cpu.decode.code_lines;

const Recorded = struct {
    base: u32 = 0,
    offset: u64 = 0,
    initiator: Initiator = .none,
    pre: [8]u8 = @splat(0xAA),
    pre_len: usize = 0,
};

var trail_writes: [16]Recorded = undefined;
var trail_write_count: usize = 0;
var trail_barriers: [40]observer.Barrier = undefined;
var trail_barrier_count: usize = 0;

fn reset() void {
    trail_write_count = 0;
    trail_barrier_count = 0;
}

fn bytesThunk(ctx: *anyopaque, write: observer.Write) void {
    _ = ctx;
    const slot = &trail_writes[trail_write_count % trail_writes.len];
    slot.* = .{ .base = write.base, .offset = write.offset, .initiator = write.initiator };
    const n = @min(write.pre.len, slot.pre.len);
    @memcpy(slot.pre[0..n], write.pre[0..n]);
    slot.pre_len = n;
    trail_write_count += 1;
}

fn barrierThunk(ctx: *anyopaque, event: observer.Barrier) void {
    _ = ctx;
    trail_barriers[trail_barrier_count % trail_barriers.len] = event;
    trail_barrier_count += 1;
}

const vtable = observer.Observer.VTable{ .bytes = bytesThunk, .barrier = barrierThunk };

var obs_storage: observer.Observer = undefined;

fn listen(store: *Store) void {
    obs_storage = .{ .ctx = @ptrCast(store), .vtable = &vtable };
    store.observer = &obs_storage;
}

fn freshLines() code_lines.CodeLines {
    var lines: code_lines.CodeLines = undefined;
    lines.clear();
    return lines;
}

test "a store write feeds the trail the pre-image, the initiator and the canonical base" {
    var store = try Store.init(null);
    defer store.deinit();
    reset();
    listen(&store);
    try store.write(.none, memmap.sram_base + 0x10, &.{ 1, 2, 3 });
    try std.testing.expectEqual(@as(usize, 1), trail_write_count);
    try std.testing.expectEqual(memmap.sram_base, trail_writes[0].base);
    try std.testing.expectEqual(@as(u64, 0x10), trail_writes[0].offset);
    try std.testing.expectEqual(Initiator.none, trail_writes[0].initiator);
    try std.testing.expectEqual(@as(usize, 3), trail_writes[0].pre_len);
    try std.testing.expectEqual(@as(u8, 0), trail_writes[0].pre[0]);
    try store.write(.cpu1, memmap.ns_sram_base + 0x10, &.{9});
    try std.testing.expectEqual(@as(usize, 2), trail_write_count);
    try std.testing.expectEqual(memmap.sram_base, trail_writes[1].base);
    try std.testing.expectEqual(Initiator.cpu1, trail_writes[1].initiator);
    try std.testing.expectEqual(@as(u8, 1), trail_writes[1].pre[0]);
    try store.write(.dmac, memmap.dtcm_base + 4, &.{ 5, 6 });
    try std.testing.expectEqual(memmap.dtcm_base, trail_writes[2].base);
}

test "the core's fast path feeds the same hook and drops the block" {
    var store = try Store.init(null);
    defer store.deinit();
    reset();
    listen(&store);
    var cache = freshLines();
    cache.mark(memmap.sram_base + 0x40, memmap.sram_base + 0x48);
    try store.fanMut().attach(&cache);
    defer store.fanMut().detach(&cache);

    var memory = MemoryBus{ .store = &store, .initiator = .cpu0, .fast_enabled = true };
    var view = memory.view();
    try view.write(memmap.sram_base + 0x44, &.{ 0xFF, 0xFF, 0xFF, 0xFF });
    try std.testing.expectEqual(@as(usize, 1), trail_write_count);
    try std.testing.expectEqual(memmap.sram_base, trail_writes[0].base);
    try std.testing.expectEqual(@as(u64, 0x44), trail_writes[0].offset);
    try std.testing.expectEqual(Initiator.cpu0, trail_writes[0].initiator);
    try std.testing.expectEqual(@as(u8, 0), trail_writes[0].pre[0]);
    try std.testing.expect(!cache.marked(memmap.sram_base + 0x40));
    try std.testing.expect(cache.dirty);
}

test "a write through a guest drops blocks in both cores' caches" {
    var first = try Store.init(null);
    defer first.deinit();
    var second = try Store.init(&first);
    defer second.deinit();
    reset();
    listen(&first);
    var a = freshLines();
    var b = freshLines();
    a.mark(memmap.sram_base + 0x40, memmap.sram_base + 0x44);
    b.mark(memmap.ns_sram_base + 0x40, memmap.ns_sram_base + 0x44);
    try first.fanMut().attach(&a);
    try second.fanMut().attach(&b);
    defer first.fanMut().detach(&a);
    defer second.fanMut().detach(&b);

    const guest = Guest{ .store = &second, .initiator = .cpu1 };
    try guest.write(memmap.ns_sram_base + 0x42, &.{1});
    try std.testing.expectEqual(@as(usize, 1), trail_write_count);
    try std.testing.expectEqual(memmap.sram_base, trail_writes[0].base);
    try std.testing.expect(!a.marked(memmap.sram_base + 0x40));
    try std.testing.expect(!b.marked(memmap.ns_sram_base + 0x40));
}

test "map, wipe and the mapped window raise barriers and wipe drops blocks" {
    var store = try Store.init(null);
    defer store.deinit();
    reset();
    listen(&store);
    var cache = freshLines();
    cache.mark(memmap.mram_base, memmap.mram_base + 8);
    try store.fanMut().attach(&cache);
    defer store.fanMut().detach(&cache);

    try store.map(0x6000_0000, 16);
    try std.testing.expect(trail_barriers[0] == .mapped);
    try std.testing.expectEqual(@as(u32, 0x6000_0000), trail_barriers[0].mapped.base);
    try std.testing.expectEqual(@as(u32, 16), trail_barriers[0].mapped.size);
    try store.write(.none, 0x6000_0000 + 4, &.{5});
    try std.testing.expectEqual(@as(u32, 0x6000_0000), trail_writes[0].base);
    try std.testing.expectEqual(@as(u64, 4), trail_writes[0].offset);

    store.wipe();
    try std.testing.expect(trail_barriers[1] == .wipe);
    try std.testing.expect(cache.dirty);
    try std.testing.expect(!cache.marked(memmap.mram_base));
    try std.testing.expect(store.span(0x6000_0000, 1) == null);
}

test "the raw restore bypasses the hook but the blocks still drop" {
    var store = try Store.init(null);
    defer store.deinit();
    reset();
    listen(&store);
    var cache = freshLines();
    cache.mark(memmap.sram_base + 0x40, memmap.sram_base + 0x44);
    try store.fanMut().attach(&cache);
    defer store.fanMut().detach(&cache);

    try store.rawWrite(memmap.sram_base + 0x42, &.{ 7, 7 });
    try std.testing.expectEqual(@as(usize, 0), trail_write_count);
    try std.testing.expect(!cache.marked(memmap.sram_base + 0x40));
    try std.testing.expectEqual(@as(u8, 7), store.span(memmap.sram_base + 0x42, 1).?[0]);
}

test "two machines never interfere, and a machine holds two caches" {
    var first = try Store.init(null);
    defer first.deinit();
    var second = try Store.init(null);
    defer second.deinit();
    reset();
    var a = freshLines();
    var b = freshLines();
    var spare = freshLines();
    a.mark(memmap.sram_base + 0x40, memmap.sram_base + 0x44);
    b.mark(memmap.sram_base + 0x40, memmap.sram_base + 0x44);
    try first.fanMut().attach(&a);
    try first.fanMut().attach(&spare);
    try second.fanMut().attach(&b);
    defer first.fanMut().detach(&a);
    defer first.fanMut().detach(&spare);
    defer second.fanMut().detach(&b);

    const guest = Guest{ .store = &first, .initiator = .none };
    try guest.write(memmap.sram_base + 0x42, &.{1});
    try std.testing.expect(!a.marked(memmap.sram_base + 0x40));
    try std.testing.expect(b.marked(memmap.sram_base + 0x40));
    try std.testing.expect(!spare.marked(memmap.sram_base + 0x40));
    try std.testing.expectError(error.TooManyCaches, first.fanMut().attach(&trail_lines));
}

var trail_lines: code_lines.CodeLines = undefined;

test "a missed hook is caught" {
    var store = try Store.init(null);
    defer store.deinit();
    reset();
    listen(&store);
    const shadow = try std.heap.page_allocator.alloc(u8, 64);
    defer std.heap.page_allocator.free(shadow);
    @memcpy(shadow, store.span(memmap.sram_base, 64).?);
    try store.write(.none, memmap.sram_base + 4, &.{ 1, 2 });
    @memcpy(shadow[4..6], store.span(memmap.sram_base + 4, 2).?);
    try std.testing.expectEqualSlices(u8, shadow, store.span(memmap.sram_base, 64).?);
    // The negative control: a mutation that skips the hook leaves the
    // shadow behind, which is how a missed write is caught.
    var sram_index: ?usize = null;
    for (memmap.ram, 0..) |entry, index| {
        if (entry.base == memmap.sram_base) sram_index = index;
    }
    const sram = store.pages[sram_index.?].?;
    sram[8] = 0xAA;
    try std.testing.expect(!std.mem.eql(u8, shadow, store.span(memmap.sram_base, 64).?));
}

test "a refused map changes nothing and records no barrier" {
    var store = try Store.init(null);
    defer store.deinit();
    reset();
    listen(&store);
    try store.map(0x6000_0000, 16);
    var filled: usize = 1;
    while (filled < 32) : (filled += 1) try store.map(0x6000_0000 + @as(u32, @intCast(filled)) * 0x1000, 16);
    try std.testing.expectError(error.Full, store.map(0x6000_0000 + 32 * 0x1000, 16));
    try std.testing.expectEqual(@as(u8, 0), store.span(0x6000_0000, 1).?[0]);
    try std.testing.expectEqual(@as(usize, 32), trail_barrier_count);
}
