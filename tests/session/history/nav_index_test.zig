//! Tests for src/session/history/nav_index.zig (Slice 22.4).
//! Covers frame indexing, iteration slot accounting through skipped trips,
//! marker arrival indexing, RTOS thread transitions, and ISR events.
const std = @import("std");
const ra8 = @import("ra8");
const nav_index = ra8.session.history_nav_index;
const scheduler = ra8.chip.core.scheduler;

const Pos = scheduler.Position;
const Phase = ra8.session.history_position.Phase;

fn pos(branch: u32, r: u64, phase: Phase) Pos {
    return .{ .branch = branch, .r = r, .phase = phase, .o = 0, .gap = .retired };
}

test "nav index records and looks up frames with line-aware prev and next" {
    const allocator = std.testing.allocator;
    var idx = nav_index.NavIndex.init(allocator);
    defer idx.deinit();

    const f0 = try idx.addFrame(pos(0, 10, .board), 10_000);
    const f1 = try idx.addFrame(pos(0, 20, .board), 20_000);
    const f2 = try idx.addFrame(pos(0, 30, .board), 30_000);

    try std.testing.expectEqual(@as(u64, 0), f0);
    try std.testing.expectEqual(@as(u64, 1), f1);
    try std.testing.expectEqual(@as(u64, 2), f2);
    try std.testing.expectEqual(@as(usize, 3), idx.frameCount());

    try std.testing.expectEqual(pos(0, 20, .board), idx.getFrame(1).?);
    try std.testing.expectEqual(@as(?Pos, null), idx.getFrame(99));

    // prevFrame from round 25 returns frame 1 at round 20
    const prev = idx.prevFrame(pos(0, 25, .board), null, null);
    try std.testing.expect(prev != null);
    try std.testing.expectEqual(pos(0, 20, .board), prev.?);

    // nextFrame from round 15 returns frame 1 at round 20
    const next = idx.nextFrame(pos(0, 15, .board), null, null);
    try std.testing.expect(next != null);
    try std.testing.expectEqual(pos(0, 20, .board), next.?);
}

test "iteration indexing counts architectural slots with skipped trip advances" {
    const allocator = std.testing.allocator;
    var idx = nav_index.NavIndex.init(allocator);
    defer idx.deinit();

    idx.advanceSlots(100);
    const it1 = try idx.addIteration(pos(0, 50, .cpu0));
    try std.testing.expectEqual(@as(u64, 1), it1);
    try std.testing.expectEqual(@as(u64, 100), idx.getIterationSlots(1).?);

    // Skip trip of k=10 iterations of n=4 instructions = 40 slots
    idx.advanceSlots(4 * 10);
    idx.advanceSlots(50);
    const it2 = try idx.addIteration(pos(0, 120, .cpu0));
    try std.testing.expectEqual(@as(u64, 2), it2);
    // 100 + 40 + 50 = 190 slots
    try std.testing.expectEqual(@as(u64, 190), idx.getIterationSlots(2).?);

    try std.testing.expectEqual(pos(0, 50, .cpu0), idx.getIteration(1).?);
    try std.testing.expectEqual(pos(0, 120, .cpu0), idx.getIteration(2).?);
    try std.testing.expectEqual(@as(?Pos, null), idx.getIteration(3));
}

test "marker arrivals and bookmarks index positions faithfully" {
    const allocator = std.testing.allocator;
    var idx = nav_index.NavIndex.init(allocator);
    defer idx.deinit();

    const arr1 = try idx.addMarkerArrival("loop_start", 0x0800_1000, pos(0, 10, .cpu0));
    const arr2 = try idx.addMarkerArrival("loop_start", 0x0800_1000, pos(0, 40, .cpu0));
    try std.testing.expectEqual(@as(u64, 1), arr1);
    try std.testing.expectEqual(@as(u64, 2), arr2);

    try std.testing.expectEqual(pos(0, 10, .cpu0), idx.getMarkerArrival("loop_start", 1).?);
    try std.testing.expectEqual(pos(0, 40, .cpu0), idx.getMarkerArrival("loop_start", 2).?);
    try std.testing.expectEqual(@as(?Pos, null), idx.getMarkerArrival("loop_start", 3));

    // By point address
    try std.testing.expectEqual(pos(0, 10, .cpu0), idx.getPointArrival(0x0800_1000, 1).?);
    try std.testing.expectEqual(pos(0, 40, .cpu0), idx.getPointArrival(0x0800_1000, 2).?);
    try std.testing.expectEqual(@as(?Pos, null), idx.getPointArrival(0x0800_1000, 3));

    // Bookmarks
    try idx.setBookmark("checkpoint_alpha", pos(0, 100, .board));
    try std.testing.expectEqual(pos(0, 100, .board), idx.getBookmark("checkpoint_alpha").?);
    try std.testing.expectEqual(@as(?Pos, null), idx.getBookmark("non_existent"));
}

test "rtos thread switches and isr events are indexed by position" {
    const allocator = std.testing.allocator;
    var idx = nav_index.NavIndex.init(allocator);
    defer idx.deinit();

    try idx.addRtosSwitch(0x1000, 0x2000, pos(0, 15, .cpu0), 0);
    try idx.addRtosSwitch(0x2000, 0x3000, pos(0, 45, .cpu0), 0);
    try std.testing.expectEqual(@as(usize, 2), idx.rtosSwitchCount());

    const prev_sw = idx.prevRtosSwitch(pos(0, 30, .cpu0), null, null);
    try std.testing.expect(prev_sw != null);
    try std.testing.expectEqual(pos(0, 15, .cpu0), prev_sw.?);

    const next_sw = idx.nextRtosSwitch(pos(0, 30, .cpu0), null, null);
    try std.testing.expect(next_sw != null);
    try std.testing.expectEqual(pos(0, 45, .cpu0), next_sw.?);

    try idx.addIsr(15, true, pos(0, 22, .cpu0), 0);
    try idx.addIsr(15, false, pos(0, 28, .cpu0), 0);
    try std.testing.expectEqual(@as(usize, 2), idx.isrTransitionCount());

    const prev_isr = idx.prevIsr(pos(0, 25, .cpu0), null, null);
    try std.testing.expect(prev_isr != null);
    try std.testing.expectEqual(pos(0, 22, .cpu0), prev_isr.?);

    const next_isr = idx.nextIsr(pos(0, 25, .cpu0), null, null);
    try std.testing.expect(next_isr != null);
    try std.testing.expectEqual(pos(0, 28, .cpu0), next_isr.?);
}
