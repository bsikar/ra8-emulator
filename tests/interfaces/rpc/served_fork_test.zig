//! The served path end to end (time-travel design section 11): a session
//! opened with a disk history has the persistent recorder, the router, the
//! image identity, the async queue and the C6 hold attached, and a fork from
//! a seek into the past writes its own segment on the host's store.
const std = @import("std");
const ra8 = @import("ra8");

const setup = ra8.rpc.served_setup;
const history = ra8.host.history;
const transport = ra8.session.transport;
const record = ra8.session.history_record;
const format = ra8.session.history_format;
const seek_facts = ra8.session.history_seek_facts;

const image = "tests/fixtures/dfu/dfu_bootloader.elf";

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

const Names = struct {
    gpa: std.mem.Allocator,
    list: std.ArrayList([]u8) = .empty,

    fn visit(context: *anyopaque, name: []const u8, size: u64) anyerror!void {
        _ = size;
        const self: *Names = @ptrCast(@alignCast(context));
        try self.list.append(self.gpa, try self.gpa.dupe(u8, name));
    }

    fn has(self: *const Names, name: []const u8) bool {
        for (self.list.items) |one| if (std.mem.eql(u8, one, name)) return true;
        return false;
    }

    fn deinit(self: *Names) void {
        for (self.list.items) |one| self.gpa.free(one);
        self.list.deinit(self.gpa);
    }
};

/// Seeks the served session back to checkpoint `index`, in the past of
/// the line's recorded end; answers the facts the seek planned from.
fn rewind(gpa: std.mem.Allocator, served: *setup.Served, index: usize) !seek_facts.Facts {
    const t = served.owner.transport();
    const bridge = t.history.?;
    const facts = try seek_facts.gather(gpa, try bridge.logBytes.?(bridge.context));
    errdefer gpa.free(facts.checkpoints);
    try std.testing.expect(facts.checkpoints.len > index + 1);
    const first = facts.checkpoints[index].position;
    const text = try std.fmt.allocPrint(gpa, "{d}:{s}:{d}:{s}", .{ first.r, @tagName(first.phase), first.o, @tagName(first.gap) });
    defer gpa.free(text);
    var wall = FakeWall{};
    _ = try t.command(.{ .seek = .{ .target = text } });
    const pumped = try t.pump(wall.wall(), wall.now_ns + 4_000_000);
    try std.testing.expect(pumped.finished != null);
    return facts;
}

test "a served disk history attaches its recording parts and a past write forks into its own segment" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);

    var served: setup.Served = undefined;
    try served.open(gpa, std.testing.io, image, null, .{ .root = root, .checkpoint_every = 1 });
    defer served.deinit();
    const session = served.owner.session();

    try std.testing.expect(session.persistent_recorder != null);
    try std.testing.expect(session.fork_router != null);
    try std.testing.expect(session.graph_sink != null);
    try std.testing.expect(session.async_traffic.queue != null);
    try std.testing.expect(session.image_identity[0] != null);
    try std.testing.expect(served.owner.board().c6.wire.bridge.hold != null);

    _ = try session.run(.cpu0, .run);
    const end = session.fork_router.?.recordedEnd();
    try std.testing.expect(end.r > 0);

    const t = served.owner.transport();
    const bridge = t.history.?;
    const facts = try rewind(gpa, &served, 0);
    defer gpa.free(facts.checkpoints);
    try std.testing.expect(ra8.session.line.inPast(session));

    // The write forks after its confirmation; the recorder switched to the
    // child's own segment, which opens with the Branch record.
    try std.testing.expectError(error.ForkNeedsConfirmation, session.write(.cpu0, 0x2000_0000, "\x5A"));
    try session.confirmFork();
    try std.testing.expectEqual(@as(u32, 1), session.fork_router.?.active_line);
    try std.testing.expectEqual(@as(u32, 1), session.persistent_recorder.?.segment.branch);

    const store = history.storage.Store.from(&served.history.?.session);
    var names: Names = .{ .gpa = gpa };
    defer names.deinit();
    try store.vtable.list(store.context, .log, .{ .context = &names, .visit = &Names.visit });
    try std.testing.expect(names.has("events-0"));
    try std.testing.expect(names.has("events-1-0"));

    const child = try store.vtable.open(store.context, .log, "events-1-0", .read);
    defer child.vtable.close(child.context);
    var bytes: [512]u8 = undefined;
    const got = try child.vtable.read(child.context, 0, &bytes);
    const head = try format.decode(bytes[0..got]);
    try std.testing.expectEqual(@backingInt(record.Kind.branch), head.frame.kind);
    const branch = try record.decodeBranch(head.frame.payload);
    try std.testing.expectEqual(@as(u32, 1), branch.branch.id);
    const second = try format.decode(bytes[head.consumed..got]);
    try std.testing.expectEqual(@backingInt(record.Kind.intervention), second.frame.kind);
    try std.testing.expectEqual(record.Intervention.What.memory_write, (try record.decodeIntervention(second.frame.payload)).intervention.what);

    // The parent's segment still holds its future: the read-back of every
    // segment carries the checkpoints the child line's prefix needs.
    const all = try bridge.logBytes.?(bridge.context);
    const after = try seek_facts.gather(gpa, all);
    defer gpa.free(after.checkpoints);
    try std.testing.expect(after.checkpoints.len >= facts.checkpoints.len);
}

test "playing over the recorded past records nothing again and re-checkpoints nothing" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);

    var served: setup.Served = undefined;
    try served.open(gpa, std.testing.io, image, null, .{ .root = root, .checkpoint_every = 1 });
    defer served.deinit();
    const session = served.owner.session();
    _ = try session.run(.cpu0, .run);
    const facts = try rewind(gpa, &served, 0);
    defer gpa.free(facts.checkpoints);

    const rec = session.persistent_recorder.?;
    try rec.commit(0);
    const logged = rec.history_bytes;
    const objects = rec.object_bytes;
    const end = session.fork_router.?.recordedEnd();
    var steps: usize = 0;
    while (ra8.session.line.inPast(session) and steps < 400) : (steps += 1) _ = try session.run(.cpu0, .step);
    try std.testing.expect(steps > 0);
    try rec.commit(0);
    // The line's own future was walked, and not one byte of it was written twice.
    try std.testing.expectEqual(logged, rec.history_bytes);
    try std.testing.expectEqual(objects, rec.object_bytes);
    try std.testing.expect(std.meta.eql(end, session.fork_router.?.recordedEnd()));
    try std.testing.expect(!session.replaying);
}

test "a seek to a point on the shared prefix keeps the session on its child line" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);

    var served: setup.Served = undefined;
    try served.open(gpa, std.testing.io, image, null, .{ .root = root, .checkpoint_every = 1 });
    defer served.deinit();
    const session = served.owner.session();
    _ = try session.run(.cpu0, .run);
    const facts = try rewind(gpa, &served, 1);
    defer gpa.free(facts.checkpoints);
    try std.testing.expectError(error.ForkNeedsConfirmation, session.write(.cpu0, 0x2000_0000, "\x01"));
    try session.confirmFork();
    try std.testing.expectEqual(@as(u32, 1), session.fork_router.?.active_line);

    // An unnamed position before the fork is the root's segment on the
    // child's line: the machine goes there and the line stays.
    const earlier = try rewind(gpa, &served, 0);
    defer gpa.free(earlier.checkpoints);
    try std.testing.expectEqual(@as(u32, 1), session.fork_router.?.active_line);
    try std.testing.expectEqual(earlier.checkpoints[0].position.r, session.grid.?.at.r);
    try std.testing.expectEqual(@as(u32, 1), session.fork_router.?.graph.?.active_branch);
}
