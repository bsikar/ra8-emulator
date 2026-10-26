//! The served history bridge reports the session's reverse window in its
//! facts, so the transport's planners can pick it as a base in production.
const std = @import("std");
const ra8 = @import("ra8");
const rig = @import("../../session/history/window_rig.zig");

const setup = ra8.rpc.served_setup;
const bridge_mod = ra8.rpc.history_bridge;
const budget = ra8.host.history.budget;

const gpa = std.testing.allocator;

test "the bridge's facts carry the window's span, cursor, line and slot count" {
    var served: setup.Served = undefined;
    try served.open(gpa, std.testing.io, rig.image_path, rig.profile, .{ .ram_budget = 256 * budget.bytes.mib });
    defer served.deinit();
    try rig.countFixture(&served.owner);
    const session = served.owner.session();
    try session.setRunBudget(.cpu0, 1);
    _ = try session.run(.cpu0, .cont);
    try rig.runCount(&served.owner, 40);

    const facts = try bridge_mod.Bridge.facts(&served.bridge.?);
    const window = facts.window orelse return error.TestExpectedWindow;
    const w = session.window.?;
    try std.testing.expectEqual(@as(u64, 40), window.slots);
    try std.testing.expect(std.meta.eql(window.start, w.start().?));
    try std.testing.expect(std.meta.eql(window.end, w.end().?));
    try std.testing.expect(std.meta.eql(window.at, session.grid.?.at));
    try std.testing.expectEqual(w.line, window.line);

    // A window that holds no run is not offered to the planners.
    w.drop();
    const bare = try bridge_mod.Bridge.facts(&served.bridge.?);
    try std.testing.expect(bare.window == null);
}
