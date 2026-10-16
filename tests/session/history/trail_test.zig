//! Covers src/session/history/trail.zig: the joined trail's byte records,
//! their attribution, the labelled noncore-write watch, the undo that
//! replays back to the nearest barrier, and the poison on a lost record.
const std = @import("std");
const ra8 = @import("ra8");
const memmap = ra8.chip.core.memmap;
const memory = ra8.chip.core.cpu.memory;
const Store = memory.store.Store;
const Initiator = memory.initiator.Initiator;
const trail = ra8.session.history_trail;
const Recording = trail.Recording;

fn recording(store: *Store, slots: *[2]u64) Recording {
    return Recording.init(std.testing.allocator, .{ &slots[0], &slots[1] }, store);
}

test "a store write records its pre-image, attributed to the writing core's live slots" {
    var store = try Store.init(null);
    defer store.deinit();
    var slots: [2]u64 = .{ 3, 0 };
    var run = recording(&store, &slots);
    defer run.deinit();
    run.arm();
    try store.write(.cpu0, memmap.sram_base + 0x10, &.{ 0xAA, 0xBB });
    const records = run.slice();
    try std.testing.expectEqual(@as(usize, 1), records.len);
    switch (records[0].bytes.source) {
        .core => |who| {
            try std.testing.expectEqual(trail.Core.cpu0, who.core);
            try std.testing.expectEqual(@as(u64, 3), who.slots);
        },
        else => return error.TestUnexpectedResult,
    }
    const replayed = try run.undo();
    try std.testing.expectEqual(@as(usize, 1), replayed);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0 }, store.span(memmap.sram_base + 0x10, 2).?);
    try std.testing.expectEqual(@as(usize, 0), run.slice().len);
}

test "a noncore write raises a labelled hit where a watch overlaps, a core write does not" {
    var store = try Store.init(null);
    defer store.deinit();
    var slots: [2]u64 = .{ 0, 0 };
    var run = recording(&store, &slots);
    defer run.deinit();
    run.arm();
    try run.watch(memmap.sram_base + 0x20, 4, "ipc");
    try store.write(.dmac, memmap.sram_base + 0x22, &.{0x5A});
    try store.write(.cpu0, memmap.sram_base + 0x22, &.{0xA5});
    const hits = run.hitSlice();
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqualStrings("ipc", run.watchSlice()[hits[0].watch].label);
    switch (hits[0].source) {
        .board => |who| try std.testing.expectEqual(Initiator.dmac, who),
        else => return error.TestUnexpectedResult,
    }
}

test "the undo stops above the nearest barrier and keeps it as the boundary" {
    var store = try Store.init(null);
    defer store.deinit();
    var slots: [2]u64 = .{ 0, 5 };
    var run = recording(&store, &slots);
    defer run.deinit();
    run.arm();
    try store.write(.cpu1, memmap.mram_base + 4, &.{0x11});
    // The structural event a store wipe emits, fed through the trail's own
    // observer: the recorded bytes below it no longer describe the storage.
    run.observer.vtable.barrier(run.observer.ctx, .wipe);
    try store.write(.cpu1, memmap.mram_base + 4, &.{0x22});
    const replayed = try run.undo();
    // Only the newest byte record replays; the barrier holds the boundary,
    // and the wiped-over record stays below it.
    try std.testing.expectEqual(@as(usize, 1), replayed);
    try std.testing.expectEqual(@as(u8, 0x11), store.span(memmap.mram_base + 4, 1).?[0]);
    const kept = run.slice();
    try std.testing.expectEqual(@as(usize, 1), kept.len);
    switch (kept[0]) {
        .barrier => {},
        .bytes => return error.TestUnexpectedResult,
    }
}

test "a lost record poisons the trail instead of restoring bytes it never held" {
    var store = try Store.init(null);
    defer store.deinit();
    var slots: [2]u64 = .{ 0, 0 };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var run = Recording.init(failing.allocator(), .{ &slots[0], &slots[1] }, &store);
    defer run.deinit();
    run.arm();
    try store.write(.cpu0, memmap.sram_base + 0x30, &.{0x77});
    try std.testing.expectEqual(false, run.healthy());
    try std.testing.expectEqual(@as(usize, 0), run.slice().len);
}
