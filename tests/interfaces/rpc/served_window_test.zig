//! The served path and the reverse window (section 2.5): a served session
//! that records history sizes a window from the host's budget table, records
//! its live run into it, and plans reverse steps and forward steps through
//! the history bridge onto the window, landing on exactly the states a straight
//! run passes through.
const std = @import("std");
const ra8 = @import("ra8");
const rig = @import("../../session/history/window_rig.zig");

const setup = ra8.rpc.served_setup;
const transport = ra8.session.transport;
const engine = ra8.session.history_window_engine;
const api = ra8.session.api;
const budget = ra8.host.history.budget;

const gpa = std.testing.allocator;
const slots: usize = 150;

const FakeWall = struct {
    now_ns: u64 = 0,
    fn now(context: *anyopaque) u64 {
        const self: *FakeWall = @ptrCast(@alignCast(context));
        self.now_ns += 1_000_000;
        return self.now_ns;
    }
    fn wall(self: *FakeWall) transport.Wall {
        return .{ .context = self, .nowFn = now };
    }
};

/// A served session on the counting-loop machine, past its first step.
fn openServed(served: *setup.Served, ram_budget: u64) !void {
    try served.open(gpa, std.testing.io, rig.image_path, rig.profile, .{ .ram_budget = ram_budget });
    errdefer served.deinit();
    try rig.countFixture(&served.owner);
    const session = served.owner.session();
    try session.setRunBudget(.cpu0, 1);
    _ = try session.run(.cpu0, .cont);
}

fn expectAt(served: *setup.Served, digests: []const [32]u8, index: usize) !void {
    try std.testing.expectEqualSlices(u8, &digests[index], &try rig.digestOf(gpa, &served.owner));
}

fn step(t: *transport.Transport, back: bool, wall: *FakeWall) !void {
    const ticket = try t.command(.{ .step = .{ .core = .cpu0, .count = 1, .dir = if (back) .back else .fwd } });
    const ended = try t.finish(ticket, wall.wall(), null);
    try std.testing.expectEqual(api.Ended{ .stop = .stepped }, ended);
}

test "a served session sizes its window from the budget table and steps back and forward exactly" {
    var straight = try rig.openCounting(gpa, null);
    defer straight.deinit();
    const digests = try gpa.alloc([32]u8, slots + 1);
    defer gpa.free(digests);
    digests[0] = try rig.digestOf(gpa, &straight);
    for (1..slots + 1) |i| {
        try rig.runCount(&straight, 1);
        digests[i] = try rig.digestOf(gpa, &straight);
    }

    const ram_budget = 256 * budget.bytes.mib;
    var served: setup.Served = undefined;
    try openServed(&served, ram_budget);
    defer served.deinit();
    const session = served.owner.session();
    try expectAt(&served, digests, 0);

    try rig.runCount(&served.owner, slots);
    try expectAt(&served, digests, slots);
    const status = session.windowStatus().?;
    const share = (try budget.partition(ram_budget)).window;
    try std.testing.expectEqual(share, status.budget_bytes);
    try std.testing.expectEqual(engine.State.ready, status.state);
    // The opening step was recorded too: the window was planted before it.
    try std.testing.expectEqual(slots + 1, status.slots);
    try std.testing.expect(status.used_bytes <= status.budget_bytes);

    const t = served.owner.transport();
    var wall: FakeWall = .{};
    for (1..26) |back| {
        try step(t, true, &wall);
        try expectAt(&served, digests, slots - back);
        try std.testing.expectEqual(slots + 1 - back, session.window.?.cursor());
    }
    for (1..26) |forward| {
        try step(t, false, &wall);
        try expectAt(&served, digests, slots - 25 + forward);
    }
    try std.testing.expectEqual(slots + 1, session.window.?.cursor());
    const after = session.windowStatus().?;
    try std.testing.expectEqual(engine.State.ready, after.state);
    try std.testing.expect(after.used_bytes <= after.budget_bytes);
}
