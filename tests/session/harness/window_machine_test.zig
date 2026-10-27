//! The window's machine port over a real session: a machine that has not
//! run stands at its boundary's saved round, and the window planted there
//! describes it; a slot runs on the core whose phase it is.
const std = @import("std");
const ra8 = @import("ra8");
const rig = @import("../history/window_rig.zig");

const gpa = std.testing.allocator;

test "a window planted before the first run starts at the boundary's saved round" {
    var opened = try ra8.session.harness.open(gpa, std.testing.io, .{ .elf_path = rig.image_path, .board_profile = rig.profile });
    defer opened.deinit();
    try opened.openWindow(16 * 1024 * 1024);
    const session = opened.session();
    try std.testing.expect(session.grid == null);
    const status = session.windowStatus().?;
    try std.testing.expectEqual(ra8.session.history_window_engine.State.ready, status.state);
    try std.testing.expectEqual(@as(usize, 0), status.slots);
    try std.testing.expectEqual(@as(u64, 0), status.start.?.r);
    try std.testing.expect(std.meta.eql(status.start.?, status.end.?));

    // The first slot extends the window planted there, without planting again.
    try rig.countFixture(&opened);
    try session.setRunBudget(.cpu0, 1);
    _ = try session.run(.cpu0, .cont);
    try std.testing.expect(session.windowStatus().?.slots <= 1);
}
