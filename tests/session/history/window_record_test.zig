//! Reverse window slot recording tests: complex slots carry a digest and
//! redo by re-execution, a digest mismatch refuses visibly at the right
//! slot and leaves the machine at its pre-state, and a structural barrier
//! replants the window after it.

const std = @import("std");
const ra8 = @import("ra8");
const rig_mod = @import("window_rig.zig");
const engine = ra8.session.history_window_engine;
const rebuild = ra8.session.history_window_rebuild;

const slots: usize = 120;

fn firstComplex(w: *engine.ReverseWindow) ?usize {
    for (0..w.count()) |i| if (w.slotAt(i).kind == .complex) return i;
    return null;
}

test "a complex slot redoes by re-execution and a digest mismatch refuses at its position" {
    var rig: rig_mod.Rig = undefined;
    try rig.open(std.testing.allocator);
    defer rig.deinit();
    var straight = try rig_mod.Straight.record(&rig, slots);
    defer straight.deinit();
    try rig.port().restoreFull(straight.base);
    var w = rig.window(64 * 1024 * 1024);
    defer w.deinit();
    try rebuild.run(&w, .{ .base = .{ .bytes = straight.base }, .end = straight.positions[slots] });

    const c = firstComplex(&w) orelse return error.NoComplexSlot;
    try std.testing.expect(!std.mem.allEqual(u8, &w.slotAt(c).digest, 0));

    // An intact digest: the re-executed slot lands on the straight run.
    try w.walkTo(c);
    try std.testing.expect(try w.redo());
    try std.testing.expectEqualSlices(u8, &straight.digests[c + 1], &try rig.digest());

    // A corrupted digest: the redo refuses, names the slot, and leaves the
    // machine and the cursor at the slot's pre-state.
    try w.walkTo(c);
    w.slotAt(c).digest[3] ^= 0x5a;
    try std.testing.expectError(error.HistoryDivergence, w.redo());
    try std.testing.expectEqual(@as(?usize, c), w.refused_slot);
    const refusal = w.refusal orelse return error.NoRefusal;
    try std.testing.expect(std.meta.eql(straight.positions[c], refusal.position));
    try std.testing.expect(std.meta.eql(w.slotAt(c).pre, refusal.position));
    try std.testing.expectEqual(c, w.cursor());
    try std.testing.expectEqualSlices(u8, &straight.digests[c], &try rig.digest());

    // The refusal renders its position for the transport to surface.
    var text: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&text);
    try refusal.format(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "HistoryDivergence at round=") != null);

    // Undo still walks back exactly past the refused slot.
    while (try w.undo()) {}
    try std.testing.expectEqualSlices(u8, &straight.digests[0], &try rig.digest());
}

test "a structural barrier drops the slots before it and replants the window" {
    var rig: rig_mod.Rig = undefined;
    try rig.open(std.testing.allocator);
    defer rig.deinit();
    var straight = try rig_mod.Straight.record(&rig, 12);
    defer straight.deinit();
    try rig.port().restoreFull(straight.base);

    rig.steps = 0;
    rig.barrier_at = 5;
    var w = rig.window(64 * 1024 * 1024);
    defer w.deinit();
    try rebuild.run(&w, .{ .base = .current, .end = straight.positions[12] });

    // The fifth slot raised the barrier: the window restarts after it.
    try std.testing.expectEqual(@as(usize, 7), w.count());
    try std.testing.expect(std.meta.eql(straight.positions[5], w.hot_at.?));
    try std.testing.expect(std.meta.eql(straight.positions[5], w.start().?));
    while (try w.undo()) {}
    try std.testing.expectEqualSlices(u8, &straight.digests[5], &try rig.digest());
}
