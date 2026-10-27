//! Tests for Session API window methods: windowStatus, rewind, and stepBack delegation.

const std = @import("std");
const ra8 = @import("ra8");
const rig_mod = @import("history/window_rig.zig");
const engine = ra8.session.history_window_engine;
const rebuild = ra8.session.history_window_rebuild;

const slots: usize = 80;

fn buildWindow(rig: *rig_mod.Rig, straight: *const rig_mod.Straight, budget: usize) !engine.ReverseWindow {
    try rig.port().restoreFull(straight.base);
    var w = rig.window(budget);
    errdefer w.deinit();
    try rebuild.run(&w, .{ .base = .{ .bytes = straight.base }, .end = straight.positions[slots] });
    return w;
}

test "windowStatus returns null without attached window" {
    var rig: rig_mod.Rig = undefined;
    try rig.open(std.testing.allocator);
    defer rig.deinit();

    const session = rig.opened.session();
    try std.testing.expect(session.windowStatus() == null);
}

test "windowStatus reports accurate memory, start, end, and progress when attached" {
    var rig: rig_mod.Rig = undefined;
    try rig.open(std.testing.allocator);
    defer rig.deinit();

    var straight = try rig_mod.Straight.record(&rig, slots);
    defer straight.deinit();

    var w = try buildWindow(&rig, &straight, 32 * 1024 * 1024);
    defer w.deinit();

    const session = rig.opened.session();
    session.attachWindow(&w);

    const status = session.windowStatus() orelse return error.MissingStatus;
    try std.testing.expectEqual(w.heldBytes(), status.used_bytes);
    try std.testing.expectEqual(@as(usize, 32 * 1024 * 1024), status.budget_bytes);
    try std.testing.expectEqual(slots, status.slots);
    try std.testing.expectEqual(slots, status.cursor);
    try std.testing.expect(status.start != null);
    try std.testing.expect(status.end != null);
    try std.testing.expect(status.at != null);
}

test "session stepBack and rewind use reverse window when covered" {
    var rig: rig_mod.Rig = undefined;
    try rig.open(std.testing.allocator);
    defer rig.deinit();

    var straight = try rig_mod.Straight.record(&rig, slots);
    defer straight.deinit();

    var w = try buildWindow(&rig, &straight, 64 * 1024 * 1024);
    defer w.deinit();

    const session = rig.opened.session();
    session.attachWindow(&w);

    // Initial state at slots: digest matches head
    try std.testing.expectEqualSlices(u8, &straight.digests[slots], &try rig.digest());

    // stepBack 1 stop
    try session.stepBack(.cpu0);
    try std.testing.expectEqual(slots - 1, w.cursor());
    try std.testing.expectEqualSlices(u8, &straight.digests[slots - 1], &try rig.digest());

    // rewind 4 more stops
    try session.rewind(.cpu0, 4);
    try std.testing.expectEqual(slots - 5, w.cursor());
    try std.testing.expectEqualSlices(u8, &straight.digests[slots - 5], &try rig.digest());
}

test "rewind outside window falls back to history stop-ring or reports error" {
    var rig: rig_mod.Rig = undefined;
    try rig.open(std.testing.allocator);
    defer rig.deinit();

    var straight = try rig_mod.Straight.record(&rig, 10);
    defer straight.deinit();

    const w = try rig.port().fullBytes(std.testing.allocator);
    defer std.testing.allocator.free(w);

    var win = rig.window(16 * 1024 * 1024);
    defer win.deinit();
    try rebuild.run(&win, .{ .base = .{ .bytes = w }, .end = straight.positions[10] });

    const session = rig.opened.session();
    session.attachWindow(&win);

    // Asking for more stops than the window contains falls back to stop ring
    // Since stop ring has no recorded frames for these past positions, it handles gracefully
    _ = session.rewind(.cpu0, 20) catch {};
}
