//! Reverse window rebuild tests: one replay from a checkpoint builds the
//! window and plants the hot checkpoint at its start, a window that
//! evicted its oldest slots rebuilds from that hot checkpoint onto the same
//! states, and a sliced rebuild reports progress and can be cancelled.

const std = @import("std");
const ra8 = @import("ra8");
const rig_mod = @import("window_rig.zig");
const engine = ra8.session.history_window_engine;
const rebuild = ra8.session.history_window_rebuild;

const slots: usize = 160;

fn hash(bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(bytes, &out, .{});
    return out;
}

test "one replay from a checkpoint builds the window and plants the hot checkpoint at its start" {
    var rig: rig_mod.Rig = undefined;
    try rig.open(std.testing.allocator);
    defer rig.deinit();
    var straight = try rig_mod.Straight.record(&rig, slots);
    defer straight.deinit();

    // The machine stands at the window's end, as at a first reverse step.
    var w = rig.window(64 * 1024 * 1024);
    defer w.deinit();
    const first: usize = 70;
    try rebuild.run(&w, .{ .base = .{ .bytes = straight.base }, .start = straight.positions[first], .end = straight.positions[slots] });
    try std.testing.expectEqual(slots - first, w.count());
    try std.testing.expect(std.meta.eql(straight.positions[first], w.hot_at.?));
    try std.testing.expectEqualSlices(u8, &straight.digests[first], &hash(w.hot));
    try std.testing.expectEqualSlices(u8, &straight.digests[slots], &try rig.digest());
    try std.testing.expectEqual(engine.State.ready, w.status().state);
    try std.testing.expect(w.covers(straight.positions[100]));
    try std.testing.expect(!w.covers(straight.positions[first - 1]));

    while (try w.undo()) {}
    try std.testing.expectEqualSlices(u8, &straight.digests[first], &try rig.digest());
}

test "a window that evicted its oldest slots rebuilds from its hot checkpoint onto the same states" {
    var rig: rig_mod.Rig = undefined;
    try rig.open(std.testing.allocator);
    defer rig.deinit();
    var straight = try rig_mod.Straight.record(&rig, slots);
    defer straight.deinit();

    var w = rig.window(64 * 1024 * 1024);
    defer w.deinit();
    try rebuild.run(&w, .{ .base = .{ .bytes = straight.base }, .end = straight.positions[slots] });
    w.budget = w.usedBytes() / 3;
    w.enforceBudget();
    try std.testing.expect(w.usedBytes() <= w.budget);
    const kept = w.count();
    const first = slots - kept;
    try std.testing.expect(first > 0);
    try std.testing.expect(std.meta.eql(straight.positions[0], w.hot_at.?));

    // Rebuild the same interval from the window's own hot checkpoint: the
    // plan copies it, since a rebuild drops the old window first.
    try rebuild.run(&w, .{ .base = .{ .bytes = w.hot }, .start = w.start().?, .end = w.end().? });
    try std.testing.expectEqual(kept, w.count());
    try std.testing.expect(std.meta.eql(straight.positions[first], w.start().?));
    try std.testing.expectEqualSlices(u8, &straight.digests[slots], &try rig.digest());
    var k: usize = 1;
    while (k <= kept) : (k += 1) {
        try std.testing.expect(try w.undo());
        try std.testing.expectEqualSlices(u8, &straight.digests[slots - k], &try rig.digest());
    }
    try std.testing.expect(!try w.undo());
}

test "a sliced rebuild reports rebuilding with progress and can be cancelled" {
    var rig: rig_mod.Rig = undefined;
    try rig.open(std.testing.allocator);
    defer rig.deinit();
    var straight = try rig_mod.Straight.record(&rig, 30);
    defer straight.deinit();

    var w = rig.window(64 * 1024 * 1024);
    defer w.deinit();
    const plan: rebuild.Plan = .{ .base = .{ .bytes = straight.base }, .start = straight.positions[10], .end = straight.positions[30] };
    try rebuild.begin(&w, plan);
    try std.testing.expectEqual(engine.State.rebuilding, w.status().state);
    try std.testing.expect(!try rebuild.slice(&w, 4));
    try std.testing.expectEqual(rebuild.Phase.seek, w.status().progress.?.phase);
    try std.testing.expect(!try rebuild.slice(&w, 4));
    try std.testing.expectEqual(@as(u64, 4), w.status().progress.?.slots);
    try std.testing.expectError(engine.Error.Rebuilding, w.undo());

    // Slice on through the seek and into recording.
    while (w.status().progress.?.phase != .record) _ = try rebuild.slice(&w, 4);
    try std.testing.expect(!try rebuild.slice(&w, 5));
    const progress = w.status().progress.?;
    try std.testing.expect(progress.slots > 10);
    try std.testing.expect(std.meta.eql(straight.positions[30], progress.target));
    try std.testing.expect(w.count() > 0);

    rebuild.cancel(&w);
    try std.testing.expectEqual(engine.State.empty, w.status().state);
    try std.testing.expectEqual(@as(usize, 0), w.count());

    // The caller restores its origin; a fresh rebuild then completes.
    try rig.port().restoreFull(straight.base);
    try rebuild.begin(&w, plan);
    while (!try rebuild.slice(&w, 7)) {}
    try std.testing.expectEqual(@as(usize, 20), w.count());
    try std.testing.expectEqualSlices(u8, &straight.digests[30], &try rig.digest());
}
