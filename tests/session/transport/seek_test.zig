//! Transport seek tests: restoring a checkpoint base, replaying forward
//! past the base, estimating ETA from measured replay rate, phase-precise
//! landing, and refusal handling without a bridge or past the log.

const std = @import("std");
const ra8 = @import("ra8");
const transport = ra8.session.transport;
const fakes = @import("../history_fakes.zig");
const seek_engine_mod = ra8.session.history_seek_engine;
const seek_facts_mod = ra8.session.history_seek_facts;
const position_mod = ra8.session.history_position;

const history_elf = "tests/fixtures/dfu/dfu_bootloader.elf";

/// A wall the test drives: one millisecond per read, so a pump loop makes
/// progress and terminates on its own bound.
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

/// The bridge the seek tests bind: facts gathered from the in-memory log
/// the recorder committed, restores from the in-memory object space, and
/// the live cursor's position from the boundary grid. The bridge owns one
/// gathered facts at a time; the next gather frees the last.
const TestBridge = struct {
    gpa: std.mem.Allocator,
    opened: *ra8.session.harness.Harness,
    sink: *fakes.Sink,
    objects: *fakes.Objects,
    prior: ?seek_facts_mod.Facts = null,

    fn bridge(self: *TestBridge) transport.Bridge {
        return .{ .context = self, .facts = facts, .restore = restore, .logBytes = logBytes };
    }

    fn logBytes(context: *anyopaque) anyerror![]const u8 {
        const self: *TestBridge = @ptrCast(@alignCast(context));
        return self.sink.bytes.items;
    }

    fn facts(context: *anyopaque) anyerror!seek_engine_mod.Facts {
        const self: *TestBridge = @ptrCast(@alignCast(context));
        if (self.prior) |old| self.gpa.free(old.checkpoints);
        const gathered = try seek_facts_mod.gather(self.gpa, self.sink.bytes.items);
        self.prior = gathered;
        // A never-run machine has no grid: its cursor sits at or before
        // every checkpoint, which a zeroed position says.
        if (self.opened.session().grid) |grid| return .{ .current = grid.at, .checkpoints = gathered.checkpoints };
        return .{ .current = .{}, .checkpoints = gathered.checkpoints };
    }

    fn restore(context: *anyopaque, object: []const u8) anyerror!void {
        const self: *TestBridge = @ptrCast(@alignCast(context));
        const saved = self.objects.get(object) orelse return error.MissingObject;
        try self.opened.history().restoreBytes(saved);
    }

    fn deinit(self: *TestBridge) void {
        if (self.prior) |old| self.gpa.free(old.checkpoints);
    }
};

/// One recorded position as the target text a seek carries.
fn targetText(gpa: std.mem.Allocator, p: anytype) ![]u8 {
    return std.fmt.allocPrint(gpa, "{d}:{s}:{d}:{s}", .{ p.r, @tagName(p.phase), p.o, @tagName(p.gap) });
}

test "a seek restores a checkpoint's base and lands on its round" {
    const gpa = std.testing.allocator;
    var sink: fakes.Sink = .{ .gpa = gpa };
    defer sink.deinit();
    var objects: fakes.Objects = .{ .gpa = gpa };
    defer objects.deinit();
    var opened = try ra8.session.harness.open(gpa, std.testing.io, .{
        .elf_path = history_elf,
        .checkpoint_every = 1,
        .history_storage = sink.storage(),
        .history_objects = objects.objects(),
    });
    defer opened.deinit();
    const session = opened.session();
    _ = try session.run(.cpu0, .run);

    var state = TestBridge{ .gpa = gpa, .opened = &opened, .sink = &sink, .objects = &objects };
    defer state.deinit();
    var t = transport.Transport{ .session = session };
    t.history = state.bridge();

    const facts = try TestBridge.facts(&state);
    try std.testing.expect(facts.checkpoints.len >= 2);
    // The earliest checkpoint: strictly behind the live cursor, so the
    // plan is a backward seek whose whole replay is the restore.
    const target = facts.checkpoints[0].position;
    const text = try targetText(gpa, target);
    defer gpa.free(text);

    var fake = FakeWall{};
    const ticket = try t.command(.{ .seek = .{ .target = text } });
    const pumped = try t.pump(fake.wall(), fake.now_ns + 4_000_000);
    try std.testing.expect(pumped.finished != null);
    try std.testing.expectEqual(ticket, pumped.finished.?.ticket);
    // The restore is the seek's whole replay here: the machine lands on
    // the checkpoint's round and nowhere past it.
    try std.testing.expectEqual(target.r, session.grid.?.at.r);
}

test "a seek replays forward from a checkpoint base to a round past it" {
    const gpa = std.testing.allocator;
    var sink: fakes.Sink = .{ .gpa = gpa };
    defer sink.deinit();
    var objects: fakes.Objects = .{ .gpa = gpa };
    defer objects.deinit();
    var opened = try ra8.session.harness.open(gpa, std.testing.io, .{
        .elf_path = history_elf,
        .checkpoint_every = 4,
        .history_storage = sink.storage(),
        .history_objects = objects.objects(),
    });
    defer opened.deinit();
    const session = opened.session();
    _ = try session.run(.cpu0, .run);

    var state = TestBridge{ .gpa = gpa, .opened = &opened, .sink = &sink, .objects = &objects };
    defer state.deinit();
    var t = transport.Transport{ .session = session };
    t.history = state.bridge();

    const facts = try TestBridge.facts(&state);
    try std.testing.expect(facts.checkpoints.len >= 1);
    // One round past the earliest checkpoint: no checkpoint sits there,
    // so the plan restores the earliest base and replays the round
    // between it and the target.
    const text = try std.fmt.allocPrint(gpa, "{d}:{s}:{d}:{s}", .{
        facts.checkpoints[0].position.r + 1,
        @tagName(facts.checkpoints[0].position.phase),
        facts.checkpoints[0].position.o,
        @tagName(facts.checkpoints[0].position.gap),
    });
    defer gpa.free(text);
    const target_r = facts.checkpoints[0].position.r + 1;

    var fake = FakeWall{};
    const ticket = try t.command(.{ .seek = .{ .target = text } });
    const pumped = try t.pump(fake.wall(), fake.now_ns + 4_000_000);
    try std.testing.expect(pumped.finished != null);
    try std.testing.expectEqual(ticket, pumped.finished.?.ticket);
    try std.testing.expect(session.grid.?.at.r >= target_r);
}

test "a running seek quotes its eta from its measured replay rate" {
    const gpa = std.testing.allocator;
    var sink: fakes.Sink = .{ .gpa = gpa };
    defer sink.deinit();
    var objects: fakes.Objects = .{ .gpa = gpa };
    defer objects.deinit();
    var opened = try ra8.session.harness.open(gpa, std.testing.io, .{
        .elf_path = history_elf,
        .checkpoint_every = 4,
        .history_storage = sink.storage(),
        .history_objects = objects.objects(),
    });
    defer opened.deinit();
    const session = opened.session();
    _ = try session.run(.cpu0, .run);

    var state = TestBridge{ .gpa = gpa, .opened = &opened, .sink = &sink, .objects = &objects };
    defer state.deinit();
    var t = transport.Transport{ .session = session };
    t.history = state.bridge();

    const facts = try TestBridge.facts(&state);
    try std.testing.expect(facts.checkpoints.len >= 1);
    const base = facts.checkpoints[0].position;
    // The live cursor must sit strictly above the target so the seek
    // really replays, and the run must continue past the target's round
    // so the crossing slice ends on its budget rather than on the
    // firmware's end: extend the run until the cursor is two rounds
    // past the earliest checkpoint.
    var guard: usize = 0;
    while (session.grid.?.at.r < base.r + 2 and guard < 8) : (guard += 1) {
        _ = try session.run(.cpu0, .cont);
    }
    try std.testing.expect(session.grid.?.at.r >= base.r + 2);
    // One round past the earliest checkpoint. Each pump here is exactly
    // one slice, so the slice that crosses into the target's round
    // reports while the job still runs and the estimate is quotable.
    const text = try std.fmt.allocPrint(gpa, "{d}:{s}:{d}:{s}", .{
        base.r + 1,
        @tagName(base.phase),
        base.o,
        @tagName(base.gap),
    });
    defer gpa.free(text);
    // A budget far under the replay's cost keeps any single run slice
    // from swallowing it.
    try session.setRunBudget(.cpu0, 100_000);

    var fake = FakeWall{};
    const ticket = try t.command(.{ .seek = .{ .target = text } });
    var first: ?u64 = null;
    var last: ?u64 = null;
    var landed: ?u64 = null;
    while (landed == null) {
        const pumped = try t.pump(fake.wall(), fake.now_ns + 2_000_000);
        if (pumped.report.progress.eta_ns) |eta| {
            if (first == null) first = eta;
            last = eta;
        }
        if (pumped.finished) |fin| landed = fin.ticket;
    }
    try std.testing.expectEqual(ticket, landed.?);
    // The estimate was quoted while the replay ran, and it never grew
    // as the replay consumed the rounds it was quoted from.
    try std.testing.expect(first != null);
    try std.testing.expect(last != null);
    try std.testing.expect(last.? <= first.?);
    // The job is over: the report is halted and quotes no estimate.
    const report = t.report();
    try std.testing.expect(report.phase == .halted);
    try std.testing.expect(report.progress.eta_ns == null);
}

test "a seek to a later phase of the checkpoint's round runs past the restore" {
    const gpa = std.testing.allocator;
    var sink: fakes.Sink = .{ .gpa = gpa };
    defer sink.deinit();
    var objects: fakes.Objects = .{ .gpa = gpa };
    defer objects.deinit();
    var opened = try ra8.session.harness.open(gpa, std.testing.io, .{
        .elf_path = history_elf,
        .checkpoint_every = 1,
        .history_storage = sink.storage(),
        .history_objects = objects.objects(),
    });
    defer opened.deinit();
    const session = opened.session();
    _ = try session.run(.cpu0, .run);

    var state = TestBridge{ .gpa = gpa, .opened = &opened, .sink = &sink, .objects = &objects };
    defer state.deinit();
    var t = transport.Transport{ .session = session };
    t.history = state.bridge();

    const facts = try TestBridge.facts(&state);
    try std.testing.expect(facts.checkpoints.len >= 1);
    // One slot later in the checkpoint's own round and phase: the
    // restore alone cannot satisfy it, so the seek must run the round
    // forward to the target's phase instead of ending on the restore.
    const base = facts.checkpoints[0].position;
    const text = try std.fmt.allocPrint(gpa, "{d}:{s}:{d}:{s}", .{
        base.r,
        @tagName(base.phase),
        base.o + 1,
        @tagName(base.gap),
    });
    defer gpa.free(text);

    var fake = FakeWall{};
    const ticket = try t.command(.{ .seek = .{ .target = text } });
    const pumped = try t.pump(fake.wall(), fake.now_ns + 4_000_000);
    try std.testing.expect(pumped.finished != null);
    try std.testing.expectEqual(ticket, pumped.finished.?.ticket);
    // The landing never sits on the checkpoint it restored from: the
    // position reached the target's phase, or the round past it.
    const landed = session.grid.?.at;
    const ord = ra8.session.history_position.compare(landed, base) catch return error.TestUnexpectedResult;
    try std.testing.expectEqual(std.math.Order.gt, ord);
}

test "a seek without a bridge, on a pending kind, or past the log stays refused" {
    const gpa = std.testing.allocator;
    var opened = try ra8.session.harness.open(gpa, std.testing.io, .{ .elf_path = history_elf });
    defer opened.deinit();
    var t = transport.Transport{ .session = opened.session() };
    try std.testing.expectError(transport.Error.NotReady, t.command(.{ .seek = .{ .target = "3:cpu1:4:polled" } }));

    // With a bridge bound but nothing recorded, a position target has no
    // checkpoint base and the cursor cannot reach back, so it stays
    // refused; a time target waits for its index.
    var sink: fakes.Sink = .{ .gpa = gpa };
    defer sink.deinit();
    var objects: fakes.Objects = .{ .gpa = gpa };
    defer objects.deinit();
    // One run gives the machine its live cursor; the harness carries no
    // history storage, so the bridge sees an empty committed log.
    _ = try opened.session().run(.cpu0, .run);
    var state = TestBridge{ .gpa = gpa, .opened = &opened, .sink = &sink, .objects = &objects };
    defer state.deinit();
    t.history = state.bridge();
    try std.testing.expectError(transport.Error.NotReady, t.command(.{ .seek = .{ .target = "3:cpu1:4:polled" } }));
    try std.testing.expectError(transport.Error.NotReady, t.command(.{ .seek = .{ .target = "12.402s" } }));
}
