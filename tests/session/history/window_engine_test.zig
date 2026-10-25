//! Reverse window engine tests: undo and redo against a straight run's
//! whole-machine digests, eviction at the byte bound, and the window's
//! ownership by one line.

const std = @import("std");
const ra8 = @import("ra8");
const rig_mod = @import("window_rig.zig");
const engine = ra8.session.history_window_engine;
const rebuild = ra8.session.history_window_rebuild;

/// Enough slots to cross two board ticks at round ends (complex slots)
/// among the loop's RAM/CPU slots.
const slots: usize = 160;

fn built(rig: *rig_mod.Rig, straight: *const rig_mod.Straight, budget: usize) !engine.ReverseWindow {
    try rig.port().restoreFull(straight.base);
    var w = rig.window(budget);
    errdefer w.deinit();
    try rebuild.run(&w, .{ .base = .{ .bytes = straight.base }, .end = straight.positions[slots] });
    return w;
}

test "undo k then redo k matches the straight run at every slot" {
    var rig: rig_mod.Rig = undefined;
    try rig.open(std.testing.allocator);
    defer rig.deinit();
    var straight = try rig_mod.Straight.record(&rig, slots);
    defer straight.deinit();

    var w = try built(&rig, &straight, 64 * 1024 * 1024);
    defer w.deinit();
    try std.testing.expectEqual(slots, w.count());
    try std.testing.expectEqual(slots, w.cursor());
    try std.testing.expectEqualSlices(u8, &straight.digests[slots], &try rig.digest());

    // Both kinds of slot are on the path: the loop's RAM writes, and the
    // board's ticks every 64 cycles.
    var kinds = [2]usize{ 0, 0 };
    for (0..w.count()) |i| kinds[@backingInt(w.slotAt(i).kind)] += 1;
    try std.testing.expect(kinds[0] > 0);
    try std.testing.expect(kinds[1] > 0);

    var k: usize = 1;
    while (k <= slots) : (k += 1) {
        try std.testing.expect(try w.undo());
        try std.testing.expectEqualSlices(u8, &straight.digests[slots - k], &try rig.digest());
        try std.testing.expect(std.meta.eql(straight.positions[slots - k], w.at().?));
    }
    // Whole-window undo lands on the checkpoint root.
    try std.testing.expect(!try w.undo());
    try std.testing.expectEqualSlices(u8, &straight.digests[0], &try rig.digest());

    k = 1;
    while (k <= slots) : (k += 1) {
        try std.testing.expect(try w.redo());
        try std.testing.expectEqualSlices(u8, &straight.digests[k], &try rig.digest());
    }
    // Whole-window redo lands on the exact head.
    try std.testing.expect(!try w.redo());
    try std.testing.expectEqualSlices(u8, &straight.digests[slots], &try rig.digest());
}

test "walking to a slot in the middle and back again is exact" {
    var rig: rig_mod.Rig = undefined;
    try rig.open(std.testing.allocator);
    defer rig.deinit();
    var straight = try rig_mod.Straight.record(&rig, slots);
    defer straight.deinit();
    var w = try built(&rig, &straight, 64 * 1024 * 1024);
    defer w.deinit();

    for ([_]usize{ 7, 31, 2, 40, 0, 19 }) |index| {
        try w.walkTo(index);
        try std.testing.expectEqual(index, w.cursor());
        try std.testing.expectEqualSlices(u8, &straight.digests[index], &try rig.digest());
    }
}

test "eviction keeps the window under its byte bound and moves the start" {
    var rig: rig_mod.Rig = undefined;
    try rig.open(std.testing.allocator);
    defer rig.deinit();
    var straight = try rig_mod.Straight.record(&rig, slots);
    defer straight.deinit();

    // The unbounded window's size says what a quarter of it holds.
    var whole = try built(&rig, &straight, 64 * 1024 * 1024);
    const budget = whole.usedBytes() / 4;
    whole.deinit();

    var w = try built(&rig, &straight, budget);
    defer w.deinit();
    try std.testing.expect(w.usedBytes() <= budget);
    try std.testing.expect(w.count() > 0 and w.count() < slots);
    const first = slots - w.count();
    try std.testing.expect(std.meta.eql(straight.positions[first], w.start().?));
    try std.testing.expect(std.meta.eql(straight.positions[slots], w.end().?));
    // The hot checkpoint stays where the window was planted.
    try std.testing.expect(std.meta.eql(straight.positions[0], w.hot_at.?));

    while (try w.undo()) {}
    try std.testing.expectEqualSlices(u8, &straight.digests[first], &try rig.digest());
    while (try w.redo()) {}
    try std.testing.expectEqualSlices(u8, &straight.digests[slots], &try rig.digest());
}

test "the window drops when the machine moves to another line or forks" {
    var rig: rig_mod.Rig = undefined;
    try rig.open(std.testing.allocator);
    defer rig.deinit();
    var straight = try rig_mod.Straight.record(&rig, 8);
    defer straight.deinit();
    try rig.port().restoreFull(straight.base);
    var w = rig.window(64 * 1024 * 1024);
    defer w.deinit();
    try rebuild.run(&w, .{ .base = .current, .end = straight.positions[8] });
    try std.testing.expectEqual(engine.State.ready, w.status().state);

    // A line noted by the transport drops it.
    w.noteLine(straight.positions[0].branch + 1);
    try std.testing.expectEqual(engine.State.empty, w.status().state);
    try std.testing.expectError(engine.Error.NoWindow, w.undo());

    // A machine that moved lines underneath drops it at the next walk.
    try rig.port().restoreFull(straight.base);
    try rebuild.run(&w, .{ .base = .current, .end = straight.positions[8] });
    rig.line_shift = 1;
    try std.testing.expectError(engine.Error.OtherLine, w.undo());
    try std.testing.expectEqual(engine.State.empty, w.status().state);
    rig.line_shift = 0;

    // A fork drops it.
    try rig.port().restoreFull(straight.base);
    try rebuild.run(&w, .{ .base = .current, .end = straight.positions[8] });
    try std.testing.expectEqual(@as(usize, 8), w.count());
    w.noteFork();
    try std.testing.expectEqual(engine.State.empty, w.status().state);
    try std.testing.expectEqual(@as(usize, 0), w.usedBytes());
}
