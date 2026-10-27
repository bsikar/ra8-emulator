//! The reverse window in a real session (section 2.5): the harness builds
//! it, the live run records into it slot by slot, and reverse and forward
//! steps through the Session and the Transport land on exactly the states a
//! straight run passes through. A restore starts the window over, and a run
//! it cannot follow leaves it stale until the next live slot plants it again.
const std = @import("std");
const ra8 = @import("ra8");
const rig = @import("../history/window_rig.zig");
const transport = ra8.session.transport;
const api = ra8.session.api;
const harness_mod = ra8.session.harness;

const gpa = std.testing.allocator;
const budget: usize = 64 * 1024 * 1024;
const slots: usize = 120;

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

/// A straight run of one-instruction steps: the state after each.
const Straight = struct {
    opened: harness_mod.Harness,
    digests: [][32]u8,

    fn run(count: usize) !Straight {
        var opened = try rig.openCounting(gpa, null);
        errdefer opened.deinit();
        const digests = try gpa.alloc([32]u8, count + 1);
        errdefer gpa.free(digests);
        digests[0] = try rig.digestOf(gpa, &opened);
        for (1..count + 1) |i| {
            try rig.runCount(&opened, 1);
            digests[i] = try rig.digestOf(gpa, &opened);
        }
        return .{ .opened = opened, .digests = digests };
    }

    fn deinit(self: *Straight) void {
        gpa.free(self.digests);
        self.opened.deinit();
    }
};

fn expectAt(live: *harness_mod.Harness, straight: *const Straight, index: usize) !void {
    try std.testing.expectEqualSlices(u8, &straight.digests[index], &try rig.digestOf(gpa, live));
}

test "the live run records the window and steps back and forward match a straight run" {
    var straight = try Straight.run(slots);
    defer straight.deinit();
    var live = try rig.openCounting(gpa, budget);
    defer live.deinit();
    const session = live.session();

    try rig.runCount(&live, slots);
    try expectAt(&live, &straight, slots);
    const status = session.windowStatus().?;
    try std.testing.expectEqual(ra8.session.history_window_engine.State.ready, status.state);
    try std.testing.expectEqual(slots, status.slots);
    try std.testing.expectEqual(slots, status.cursor);
    try std.testing.expect(status.used_bytes <= status.budget_bytes);

    for (1..21) |back| {
        try session.rewind(.cpu0, 1);
        try expectAt(&live, &straight, slots - back);
        try std.testing.expectEqual(slots - back, session.window.?.cursor());
    }

    const t = live.transport();
    var wall: FakeWall = .{};
    for (1..21) |forward| {
        const ticket = try t.command(.{ .step = .{ .core = .cpu0, .count = 1, .dir = .fwd } });
        const ended = try t.finish(ticket, wall.wall(), null);
        try std.testing.expectEqual(api.Ended{ .stop = .stepped }, ended);
        try expectAt(&live, &straight, slots - 20 + forward);
    }
    try std.testing.expectEqual(slots, session.window.?.cursor());
    try std.testing.expect(session.windowStatus().?.used_bytes <= budget);
}

test "a live run past the window's budget evicts its oldest slots and still steps back exactly" {
    var straight = try Straight.run(400);
    defer straight.deinit();
    var live = try rig.openCounting(gpa, 96 * 1024);
    defer live.deinit();
    const session = live.session();

    try rig.runCount(&live, 400);
    const w = session.window.?;
    try std.testing.expect(w.count() > 1 and w.count() < 400);
    try std.testing.expect(w.usedBytes() <= 96 * 1024);
    try expectAt(&live, &straight, 400);
    for (1..11) |back| {
        try session.rewind(.cpu0, 1);
        try expectAt(&live, &straight, 400 - back);
    }
}

const Restorer = struct {
    opened: *harness_mod.Harness,
    bytes: []const u8,

    fn facts(context: *anyopaque) anyerror!ra8.session.history_seek_engine.Facts {
        _ = context;
        return error.NoHistory;
    }

    fn restore(context: *anyopaque, object: []const u8) anyerror!void {
        _ = object;
        const self: *Restorer = @ptrCast(@alignCast(context));
        try self.opened.history().restoreBytes(self.bytes);
    }
};

test "a restore drops the window and plants it again at the restored state" {
    var straight = try Straight.run(60);
    defer straight.deinit();
    var live = try rig.openCounting(gpa, budget);
    defer live.deinit();
    const session = live.session();

    var base: std.Io.Writer.Allocating = .init(gpa);
    defer base.deinit();
    try live.state.files.writeTo(&base.writer);
    try rig.runCount(&live, 80);
    try std.testing.expectEqual(@as(usize, 80), session.windowStatus().?.slots);

    // The history's own restore leaves no window describing the run before it.
    try live.history().restoreBytes(base.written());
    try std.testing.expectEqual(ra8.session.history_window_engine.State.empty, session.windowStatus().?.state);
    try expectAt(&live, &straight, 0);

    // The transport's restore plants it again, at the restored position.
    var restorer: Restorer = .{ .opened = &live, .bytes = base.written() };
    const t = live.transport();
    t.history = .{ .context = &restorer, .facts = Restorer.facts, .restore = Restorer.restore };
    try rig.runCount(&live, 80);
    try t.restoreBase(.{ .checkpoint = .{ .id = 0, .object = @splat(0), .position = session.grid.?.at } });
    const planted = session.windowStatus().?;
    try std.testing.expectEqual(ra8.session.history_window_engine.State.ready, planted.state);
    try std.testing.expectEqual(@as(usize, 0), planted.slots);
    try std.testing.expect(std.meta.eql(planted.at.?, session.grid.?.at));
    try expectAt(&live, &straight, 0);

    // Recording goes on from there, and the window is consistent.
    try rig.runCount(&live, 60);
    try std.testing.expectEqual(@as(usize, 60), session.windowStatus().?.slots);
    try expectAt(&live, &straight, 60);
    for (1..16) |back| {
        try session.rewind(.cpu0, 1);
        try expectAt(&live, &straight, 60 - back);
    }
}

test "a run the window cannot follow leaves it stale and the next live slot plants it again" {
    var straight = try Straight.run(60);
    defer straight.deinit();
    var live = try rig.openCounting(gpa, budget);
    defer live.deinit();
    const session = live.session();

    try rig.runCount(&live, 20);
    try std.testing.expectEqual(@as(usize, 20), session.windowStatus().?.slots);

    // A replayed run moves the machine without the window.
    session.setReplaying(true);
    try rig.runCount(&live, 10);
    session.setReplaying(false);
    try std.testing.expectEqual(ra8.session.history_window_engine.State.empty, session.windowStatus().?.state);

    try rig.runCount(&live, 30);
    const status = session.windowStatus().?;
    try std.testing.expectEqual(ra8.session.history_window_engine.State.ready, status.state);
    try std.testing.expectEqual(@as(usize, 30), status.slots);
    try expectAt(&live, &straight, 60);
    for (1..11) |back| {
        try session.rewind(.cpu0, 1);
        try expectAt(&live, &straight, 60 - back);
    }
}

test "a register write at the live head starts the window over so a step back stops at the write" {
    var live = try rig.openCounting(gpa, budget);
    defer live.deinit();
    const session = live.session();

    try rig.runCount(&live, 40);
    try std.testing.expectEqual(@as(usize, 40), session.windowStatus().?.slots);
    try session.setRegister(.cpu0, .r7, 0x5A5A_1234);
    const poked = try rig.digestOf(gpa, &live);
    try std.testing.expectEqual(@as(usize, 0), session.windowStatus().?.slots);

    try rig.runCount(&live, 1);
    try std.testing.expectEqual(@as(usize, 1), session.windowStatus().?.slots);
    try session.rewind(.cpu0, 1);
    try std.testing.expectEqualSlices(u8, &poked, &try rig.digestOf(gpa, &live));
    try std.testing.expectEqual(@as(u32, 0x5A5A_1234), try session.register(.cpu0, .r7));
}
