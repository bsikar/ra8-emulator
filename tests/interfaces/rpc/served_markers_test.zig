//! Late-armed markers through the served setup: arm one after recording,
//! seek to its Nth arrival, close, reopen the kept history and seek again
//! from the cache with the same position and without a second replay.
const std = @import("std");
const ra8 = @import("ra8");

const setup = ra8.rpc.served_setup;
const nav_marker = ra8.rpc.session.nav_marker;
const transport = ra8.session.transport;
const history = ra8.host.history;

const image = "tests/fixtures/dfu/dfu_bootloader.elf";
const steps = 300;

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

/// Steps the machine and answers an address its program counter came back to.
fn loopAddress(served: *setup.Served) !u32 {
    const session = served.owner.session();
    var seen: [steps]u32 = undefined;
    for (&seen) |*slot| {
        _ = try session.run(.cpu0, .step);
        slot.* = (try session.register(.cpu0, .pc)) & ~@as(u32, 1);
    }
    for (seen[0 .. steps - 1], 0..) |pc, at| {
        for (seen[at + 1 ..]) |later| if (later == pc) return pc;
    }
    return error.NoLoopInTrace;
}

fn arm(served: *setup.Served, place: []const u8) !ra8.rpc.session.rpc.NavQueryResult {
    return switch (nav_marker.markerSet(&served.context, .{ .name = "loop", .place = place })) {
        .ok => |reply| reply,
        .err => error.ArmRefused,
    };
}

fn seekMarker(served: *setup.Served, text: []const u8) !ra8.session.history_position.Position {
    const t = served.owner.transport();
    var wall = FakeWall{};
    const ticket = try t.command(.{ .seek = .{ .target = text } });
    _ = try t.finish(ticket, wall.wall(), null);
    return served.owner.session().currentPosition();
}

test "a late marker is indexed by replay, cached, and served again after a reopen" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);

    var id: history.name.Id = undefined;
    var place_buf: [16]u8 = undefined;
    var arrivals: u64 = 0;
    var landed: ra8.session.history_position.Position = undefined;
    {
        var served: setup.Served = undefined;
        try served.open(gpa, std.testing.io, image, null, .{ .root = root, .checkpoint_every = 16, .kept = true });
        defer served.deinit();
        id = served.history.?.session.id;
        const address = try loopAddress(&served);
        const place = try std.fmt.bufPrint(&place_buf, "0x{x}", .{address});
        const session = served.owner.session();
        const origin = session.currentPosition();

        const armed = try arm(&served, place);
        try std.testing.expect(armed.found == 1);
        try std.testing.expect(armed.count >= 2);
        arrivals = armed.count;
        // The replay put the machine back where it stood.
        try std.testing.expectEqual(std.math.Order.eq, try session.comparePositions(origin, session.currentPosition()));

        landed = try seekMarker(&served, "marker loop 2");
        try std.testing.expectEqual(@as(u32, address), (try session.register(.cpu0, .pc)) & ~@as(u32, 1));
        try std.testing.expectEqual(@as(usize, @intCast(arrivals)), served.nav.?.markerArrivalCount("loop"));
        try std.testing.expectEqual(landed, served.nav.?.getMarkerArrival("loop", 2).?);
    }

    var again: setup.Served = undefined;
    try again.open(gpa, std.testing.io, image, null, .{ .root = root, .checkpoint_every = 16, .reopen = &id });
    defer again.deinit();
    // The cache is back before anything runs.
    try std.testing.expectEqual(@as(usize, @intCast(arrivals)), again.nav.?.markerArrivalCount("loop"));
    const epoch = again.owner.transport().epoch;
    const rearmed = try arm(&again, "0x0");
    try std.testing.expectEqual(arrivals, rearmed.count);
    // No replay ran: the transport never restarted a job for it.
    try std.testing.expectEqual(epoch, again.owner.transport().epoch);
    const second = try seekMarker(&again, "marker loop 2");
    try std.testing.expectEqual(landed, second);
}
