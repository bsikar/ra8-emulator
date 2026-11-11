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
const dual_image = "tests/fixtures/trustzone/cpu1_pingpong_ipc.elf";
const dual_first = @embedFile("../../fixtures/trustzone/cpu1_pingpong_ipc.elf");
const dual_second = @embedFile("../../fixtures/trustzone/cpu1_pingpong_ipc_cpu1.elf");

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

test "a run too long to record leaves no window and the first reverse step builds it by replay" {
    // A multiple of the board's 64-cycle rounds: a run in one command and the
    // same run one slot at a time agree there, and only there.
    const long: usize = 5120;
    const tail: usize = 12;
    var straight = try rig.openCounting(gpa, null);
    defer straight.deinit();
    for (0..long - tail) |_| try rig.runCount(&straight, 1);
    var digests: [tail + 1][32]u8 = undefined;
    digests[0] = try rig.digestOf(gpa, &straight);
    for (1..tail + 1) |i| {
        try rig.runCount(&straight, 1);
        digests[i] = try rig.digestOf(gpa, &straight);
    }

    var served: setup.Served = undefined;
    try openServed(&served, 256 * budget.bytes.mib);
    defer served.deinit();
    const session = served.owner.session();
    try rig.runCount(&served.owner, long);
    try expectTail(&served, &digests, tail);
    try std.testing.expectEqual(engine.State.empty, session.windowStatus().?.state);

    const t = served.owner.transport();
    var wall: FakeWall = .{};
    for (1..tail + 1) |back| {
        try step(t, true, &wall);
        try expectTail(&served, &digests, tail - back);
        const status = session.windowStatus().?;
        try std.testing.expectEqual(engine.State.ready, status.state);
        try std.testing.expect(status.slots > 0 and status.used_bytes <= status.budget_bytes);
    }
}

fn expectTail(served: *setup.Served, digests: []const [32]u8, index: usize) !void {
    try std.testing.expectEqualSlices(u8, &digests[index], &try rig.digestOf(gpa, &served.owner));
}

fn stepCore(t: *transport.Transport, core: api.Core, back: bool, wall: *FakeWall) !void {
    const ticket = try t.command(.{ .step = .{ .core = core, .count = 1, .dir = if (back) .back else .fwd } });
    const ended = try t.finish(ticket, wall.wall(), null);
    try std.testing.expectEqual(api.Ended{ .stop = .stepped }, ended);
}

fn openDualServed(served: *setup.Served, ram_budget: u64) !void {
    try served.openInitial(gpa, std.testing.io, dual_image, rig.profile, .{
        .ram_budget = ram_budget,
        .checkpoint_every = 4,
    }, .{ .bytes = dual_second });
    errdefer served.deinit();
    try rig.runCount(&served.owner, 100_000);
    try std.testing.expect(served.second.?.cpu().retired > 50);
    served.owner.state.edge.idle_skip = false;
    served.owner.state.edge.timebase.per_chunk = 64;
    const session = served.owner.session();
    session.live.boundary.?.chunk = 64;
    try rig.runCount(&served.owner, 512);
    session.replantWindow();
}

/// The machine's whole save stream hashed; `loose` leaves out the debug-unit
/// section, whose cycle-clock sample counters only record when the debugger
/// last looked and so depend on how the run reached a state (whole rounds or
/// single slots), not on guest state.
fn digestFor(opened: *ra8.session.harness.Harness, loose: bool) ![32]u8 {
    if (!loose) return rig.digestOf(gpa, opened);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try opened.state.files.writeTo(&out.writer);
    var reader = try ra8.snapshot.file.Reader.open(out.written());
    var hasher = std.crypto.hash.Blake3.init(.{});
    while (try reader.next()) |section| {
        if (section.kind == .debug_units) continue;
        hasher.update(std.mem.asBytes(&@as(u32, @backingInt(section.kind))));
        hasher.update(section.payload);
    }
    var hash: [32]u8 = undefined;
    hasher.final(&hash);
    return hash;
}

const DualRef = struct {
    opened: ra8.session.harness.Harness,
    second: ra8.session.cpu1.bringup.Cpu1 = .{},
    loose: bool,
    positions: []engine.Position,
    digests: [][32]u8,

    fn recordFrom(snapshot_bytes: []const u8, skip_cpu0: u64, slot_steps: usize, loose: bool) !DualRef {
        var opened = try ra8.session.harness.open(gpa, std.testing.io, .{ .elf_path = dual_image, .elf_bytes = dual_first, .board_profile = rig.profile });
        errdefer opened.deinit();
        var second: ra8.session.cpu1.bringup.Cpu1 = .{};
        try second.openBytes(gpa, &opened, dual_second);
        errdefer second.close(gpa);
        opened.state.edge.idle_skip = false;
        opened.state.edge.timebase.per_chunk = 64;
        opened.session().live.boundary.?.chunk = 64;
        try opened.history().restoreBytes(snapshot_bytes);
        if (skip_cpu0 > 0) try rig.runCount(&opened, skip_cpu0);
        const positions = try gpa.alloc(engine.Position, slot_steps + 1);
        errdefer gpa.free(positions);
        const digests = try gpa.alloc([32]u8, slot_steps + 1);
        errdefer gpa.free(digests);
        positions[0] = opened.session().grid.?.at;
        digests[0] = try digestFor(&opened, loose);
        for (1..slot_steps + 1) |i| {
            const step_res = try opened.session().live.stepSlot(std.math.maxInt(u64), null);
            if (step_res.ended != .count) return error.UnexpectedStop;
            positions[i] = opened.session().grid.?.at;
            digests[i] = try digestFor(&opened, loose);
        }
        return .{ .opened = opened, .second = second, .loose = loose, .positions = positions, .digests = digests };
    }

    fn deinit(self: *DualRef) void {
        gpa.free(self.positions);
        gpa.free(self.digests);
        self.second.close(gpa);
        self.opened.deinit();
    }

    /// Whether the machine equals a reference state at its position. A
    /// position does not tell idle slots apart, so several reference states
    /// can share it; the machine must equal one of them exactly.
    fn matches(self: *const DualRef, served: *setup.Served) !?usize {
        const at = served.owner.session().grid.?.at;
        const actual = try digestFor(&served.owner, self.loose);
        for (self.positions, 0..) |pos, idx| {
            if (std.meta.eql(pos, at) and std.mem.eql(u8, &self.digests[idx], &actual)) return idx;
        }
        return null;
    }

    fn expectMatch(self: *const DualRef, served: *setup.Served) !usize {
        return (try self.matches(served)) orelse error.StateDiffersFromReference;
    }
};

/// A reverse step may rebuild from the checkpoint the cursor stands on or,
/// when the window runs out, from an earlier one. A replay from either holds
/// the same guest state; only the debugger's per-slot clock bookkeeping, which
/// a run that left the checkpoint in whole rounds sampled less often, differs.
fn expectEither(near: *const DualRef, far: *const DualRef, served: *setup.Served) !void {
    if (try near.matches(served) != null) return;
    _ = try far.expectMatch(served);
}

test "live dual-core window records both cores and steps back, forward and seeks with exact digests" {
    var served: setup.Served = undefined;
    try openDualServed(&served, 256 * budget.bytes.mib);
    defer served.deinit();
    const session = served.owner.session();

    var snap: std.Io.Writer.Allocating = .init(gpa);
    defer snap.deinit();
    try served.owner.state.files.writeTo(&snap.writer);
    var ref = try DualRef.recordFrom(snap.written(), 0, 520, false);
    defer ref.deinit();

    const cpu1_before = served.second.?.cpu().retired;
    try rig.runCount(&served.owner, 256);
    try std.testing.expect(served.second.?.cpu().retired > cpu1_before);
    try std.testing.expectEqual(engine.State.ready, session.windowStatus().?.state);
    _ = try ref.expectMatch(&served);

    var has_cpu0 = false;
    var has_cpu1 = false;
    const w = session.window.?;
    for (0..w.count()) |i| {
        const slot = w.slotAt(i);
        if (slot.core == .cpu0 and slot.retired) has_cpu0 = true;
        if (slot.core == .cpu1 and slot.retired) has_cpu1 = true;
    }
    try std.testing.expect(has_cpu0 and has_cpu1);

    const t = served.owner.transport();
    var wall: FakeWall = .{};
    for (0..3) |_| {
        try stepCore(t, .cpu1, true, &wall);
        _ = try ref.expectMatch(&served);
        try stepCore(t, .cpu0, true, &wall);
        _ = try ref.expectMatch(&served);
    }
    for (0..2) |_| {
        try stepCore(t, .cpu0, false, &wall);
        _ = try ref.expectMatch(&served);
        try stepCore(t, .cpu1, false, &wall);
        _ = try ref.expectMatch(&served);
    }

    var cpu1_pos: ?engine.Position = null;
    for (ref.positions) |pos| {
        if (pos.phase == .cpu1 and pos.o > 1 and w.covers(pos)) {
            cpu1_pos = pos;
            break;
        }
    }
    const target = cpu1_pos orelse return error.NoCpu1SlotInWindow;
    var seek_buf: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&seek_buf, "{d}:{d}:{s}:{d}:{s}", .{ target.branch, target.r, @tagName(target.phase), target.o, @tagName(target.gap) });
    const seek_ticket = try t.command(.{ .seek = .{ .target = text } });
    _ = try t.finish(seek_ticket, wall.wall(), null);
    try std.testing.expectEqual(target, session.grid.?.at);
    _ = try ref.expectMatch(&served);
}

fn checkpointBytes(served: *setup.Served, object: [16]u8) ![]const u8 {
    var hex: [32]u8 = undefined;
    for (object, 0..) |b, idx| _ = std.fmt.bufPrint(hex[idx * 2 ..][0..2], "{x:0>2}", .{b}) catch unreachable;
    return served.ram_history.?.get(&hex).?;
}

test "dual-core continue past 4096 slots rebuilds multi-round window within byte-evicted budget" {
    var served: setup.Served = undefined;
    try openDualServed(&served, 128 * budget.bytes.mib);
    defer served.deinit();
    const session = served.owner.session();
    session.window.?.budget = 96 * 1024;

    try rig.runCount(&served.owner, 5312);
    try std.testing.expectEqual(engine.State.empty, session.windowStatus().?.state);

    const cursor = session.grid.?.at;
    const facts = try ra8.rpc.history_bridge.Bridge.facts(&served.bridge.?);
    const base = ra8.session.history_seek_engine.backBase(cursor, facts).plan.base.checkpoint;
    // Two references: a replay from the checkpoint the first rebuild starts
    // at, and one from the checkpoint before it, where a reverse step falls
    // back when the byte-evicted window no longer holds the slot it needs.
    var near = try DualRef.recordFrom(try checkpointBytes(&served, base.object), 0, 700, true);
    defer near.deinit();
    var earlier = base;
    var best_r: u64 = 0;
    for (facts.checkpoints) |cp| {
        if (cp.position.r < base.position.r and cp.position.r >= best_r) {
            best_r = cp.position.r;
            earlier = .{ .id = cp.id, .object = cp.object, .position = cp.position };
        }
    }
    var far = try DualRef.recordFrom(try checkpointBytes(&served, earlier.object), 0, 1400, true);
    defer far.deinit();

    const t = served.owner.transport();
    var wall: FakeWall = .{};
    for (0..2) |_| {
        try stepCore(t, .cpu1, true, &wall);
        try expectEither(&near, &far, &served);
        const status = session.windowStatus().?;
        try std.testing.expectEqual(engine.State.ready, status.state);
        try std.testing.expect(session.window.?.usedBytes() <= status.budget_bytes);
        try stepCore(t, .cpu0, true, &wall);
        try expectEither(&near, &far, &served);
    }
    try std.testing.expect(!std.meta.eql(session.window.?.start().?, session.window.?.hot_at.?));
    try stepCore(t, .cpu0, false, &wall);
    try expectEither(&near, &far, &served);
}

test "cancelling a dual-core window rebuild or post-window fallback restores the origin checkpoint" {
    var served: setup.Served = undefined;
    try openDualServed(&served, 256 * budget.bytes.mib);
    defer served.deinit();
    const session = served.owner.session();
    const t = served.owner.transport();
    var wall: FakeWall = .{};

    try rig.runCount(&served.owner, 5120);
    try std.testing.expectEqual(engine.State.empty, session.windowStatus().?.state);
    const cursor = session.grid.?.at;
    const facts = try ra8.rpc.history_bridge.Bridge.facts(&served.bridge.?);
    const origin_cp = ra8.session.history_seek_engine.backBase(cursor, facts).plan.base.checkpoint.position;

    const ticket = try t.command(.{ .step = .{ .core = .cpu1, .count = 1, .dir = .back } });
    var saw_rebuilding = false;
    for (0..8) |_| {
        _ = try t.pump(wall.wall(), wall.now_ns + 1_500_000);
        if (session.windowStatus().?.state == .rebuilding) {
            saw_rebuilding = true;
            break;
        }
    }
    try std.testing.expect(saw_rebuilding);
    _ = try t.command(.pause);
    try std.testing.expectError(error.Cancelled, t.finish(ticket, wall.wall(), null));
    try std.testing.expectEqual(engine.State.ready, session.windowStatus().?.state);
    try std.testing.expectEqual(@as(usize, 0), session.windowStatus().?.slots);
    try std.testing.expectEqual(origin_cp, session.grid.?.at);

    // Part B: queued inside .window at cursor 0, falls back to earlier checkpoint, then cancelled.
    try rig.runCount(&served.owner, 320);
    const fb_cursor = session.grid.?.at;
    var fb_facts = try ra8.rpc.history_bridge.Bridge.facts(&served.bridge.?);
    fb_facts.window = null;
    const fb_origin = ra8.session.history_seek_engine.backBase(fb_cursor, fb_facts).plan.base.checkpoint.position;
    try session.window.?.walkTo(0);
    const fb_ticket = try t.command(.{ .step = .{ .core = .cpu0, .count = 1, .dir = .back } });
    for (0..3) |_| _ = try t.pump(wall.wall(), wall.now_ns + 1_500_000);
    _ = try t.command(.pause);
    try std.testing.expectError(error.Cancelled, t.finish(fb_ticket, wall.wall(), null));
    try std.testing.expectEqual(fb_origin, session.grid.?.at);
}
