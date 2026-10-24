//! Transport backward step and reverse-continue tests: queueing, discovery and
//! landing passes, settling with history_start, search for latest breakpoint hit,
//! and restoring the origin checkpoint on cancel.

const std = @import("std");
const ra8 = @import("ra8");
const transport = ra8.session.transport;
const fakes = @import("../history_fakes.zig");
const seek_engine_mod = ra8.session.history_seek_engine;
const seek_facts_mod = ra8.session.history_seek_facts;
const position_mod = ra8.session.history_position;

const history_elf = "tests/fixtures/dfu/dfu_bootloader.elf";

const image_path = "tests/fixtures/display/ra8_ui.elf";

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

/// The guest counter the count fixture increments, above the code at +0x6000.
const counter_addr = ra8.chip.core.memmap.sram_base + 0x6100;

/// The loop fixture's `b .` becomes a counting loop: `ldr r0,[r1]; adds
/// r0,#1; str r0,[r1]; b` back, so every iteration writes guest memory and
/// retires four instructions, four cycles apart.
fn countFixture(opened: *ra8.session.harness.Harness) !void {
    try loopFixture(opened);
    const at = ra8.chip.core.memmap.sram_base + 0x6000;
    try opened.guest().write(at, &.{ 0x08, 0x68, 0x40, 0x1C, 0x08, 0x60, 0xFB, 0xE7 });
    try opened.guest().writeWord(counter_addr, 0);
    const cpu = opened.primaryCpu();
    cpu.regs.low[0] = 0;
    cpu.regs.low[1] = counter_addr;
}

fn loopFixture(opened: *ra8.session.harness.Harness) !void {
    opened.state.edge.idle_skip = false;
    opened.state.edge.timebase.per_chunk = 64;
    opened.session().live.boundary.?.chunk = 64;
    const at = ra8.chip.core.memmap.sram_base + 0x6000;
    try opened.guest().write(at, &.{ 0xfe, 0xe7 });
    opened.primaryCpu().regs.pc = at;
    opened.primaryCpu().regs.primask = 1;
    opened.primaryCpu().waiting = null;
}

/// The bridge the backward tests bind: facts gathered from the in-memory log
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

test "a backward step is refused without a bridge" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image_path });
    defer opened.deinit();
    var t = transport.Transport{ .session = opened.session() };
    try std.testing.expectError(transport.Error.NotReady, t.command(.{ .step = .{ .core = .cpu0, .dir = .back } }));
}

test "a backward step queues against a bound bridge and reports its direction" {
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
    var fake = FakeWall{};
    const queued = session.grid.?.at;
    const ticket = try t.command(.{ .step = .{ .core = .cpu0, .dir = .back } });
    const report = t.report();
    try std.testing.expectEqual(@as(transport.State, .{ .stepping = .{ .core = .cpu0, .count = 1, .dir = .back } }), report.state.?);
    // The queue door answers and the job runs: discovery and landing
    // replay through the bound bridge and the machine steps back to the
    // stop before the queue-time cursor, so virtual time goes back too.
    _ = try t.finish(ticket, fake.wall(), null);
    try std.testing.expect((try position_mod.compare(session.grid.?.at, queued)) == .lt);
}

test "a backward step replays to the stop before the cursor" {
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

    const queued = session.grid.?.at;
    var fake = FakeWall{};
    const ticket = try t.command(.{ .step = .{ .core = .cpu0, .dir = .back } });
    var pumped = try t.pump(fake.wall(), fake.now_ns + 4_000_000);
    var rounds: usize = 0;
    while (pumped.finished == null) : (rounds += 1) {
        try std.testing.expect(rounds < 1_000_000);
        pumped = try t.pump(fake.wall(), fake.now_ns + 4_000_000);
    }
    try std.testing.expectEqual(ticket, pumped.finished.?.ticket);
    try std.testing.expectEqualStrings("stepped", @tagName(pumped.finished.?.ended.stop));
    const landed = session.grid.?.at;
    try std.testing.expect((try position_mod.compare(landed, queued)) == .lt);
}

test "a backward step at the log's beginning settles with history_start" {
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

    var state = TestBridge{ .gpa = gpa, .opened = &opened, .sink = &sink, .objects = &objects };
    defer state.deinit();
    var t = transport.Transport{ .session = session };
    t.history = state.bridge();

    var fake = FakeWall{};
    const ticket = try t.command(.{ .step = .{ .core = .cpu0, .dir = .back } });
    const pumped = try t.pump(fake.wall(), fake.now_ns + 4_000_000);
    try std.testing.expect(pumped.finished != null);
    try std.testing.expectEqual(ticket, pumped.finished.?.ticket);
    try std.testing.expectEqualStrings("history_start", @tagName(pumped.finished.?.ended.stop));
}

test "a reverse-continue is refused without a bridge and while a watch is armed" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image_path });
    defer opened.deinit();
    const session = opened.session();
    var t = transport.Transport{ .session = session };
    try std.testing.expectError(transport.Error.NotReady, t.command(.rcont));

    var sink: fakes.Sink = .{ .gpa = std.testing.allocator };
    defer sink.deinit();
    var objects: fakes.Objects = .{ .gpa = std.testing.allocator };
    defer objects.deinit();
    var with = transport.Transport{ .session = session };
    var state = TestBridge{ .gpa = std.testing.allocator, .opened = &opened, .sink = &sink, .objects = &objects };
    defer state.deinit();
    with.history = state.bridge();
    _ = try session.run(.cpu0, .run);
    _ = try session.setWatchpoint(.cpu0, .{ .first = counter_addr, .last = counter_addr + 3, .kind = .write });
    try std.testing.expectError(transport.Error.WatchArmed, with.command(.rcont));
}

test "a reverse-continue replays to the latest hit before the cursor" {
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
    try countFixture(&opened);
    // A first stretch with no breakpoint closed rounds behind everything
    // the reverse search replays: the loop fixture's own stop ends the
    // budget, and every closed round left a checkpoint.
    try session.setRunBudget(.cpu0, 4096);
    _ = try session.run(.cpu0, .run);
    const str_addr = ra8.chip.core.memmap.sram_base + 0x6004;
    _ = try session.setBreakpoint(.cpu0, .{ .address = str_addr });
    const first = try session.run(.cpu0, .cont);
    try std.testing.expectEqualStrings("breakpoint", @tagName(first.stop));
    const hit1 = session.grid.?.at;
    const second = try session.run(.cpu0, .cont);
    try std.testing.expectEqualStrings("breakpoint", @tagName(second.stop));
    const hit2 = session.grid.?.at;
    try std.testing.expect((try position_mod.compare(hit2, hit1)) == .gt);

    var state = TestBridge{ .gpa = gpa, .opened = &opened, .sink = &sink, .objects = &objects };
    defer state.deinit();
    var t = transport.Transport{ .session = session };
    t.history = state.bridge();
    var fake = FakeWall{};
    const ticket = try t.command(.rcont);
    var pumped = try t.pump(fake.wall(), fake.now_ns + 4_000_000);
    var rounds: usize = 0;
    while (pumped.finished == null) : (rounds += 1) {
        try std.testing.expect(rounds < 1_000_000);
        pumped = try t.pump(fake.wall(), fake.now_ns + 4_000_000);
    }
    try std.testing.expectEqual(ticket, pumped.finished.?.ticket);
    try std.testing.expectEqualStrings("breakpoint", @tagName(pumped.finished.?.ended.stop));
    const landed = session.grid.?.at;
    try std.testing.expect((try position_mod.compare(landed, hit1)) == .eq);
}

test "a reverse-continue with no stops behind it settles with history_start" {
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
    var state = TestBridge{ .gpa = gpa, .opened = &opened, .sink = &sink, .objects = &objects };
    defer state.deinit();
    var t = transport.Transport{ .session = opened.session() };
    t.history = state.bridge();
    var fake = FakeWall{};
    const ticket = try t.command(.rcont);
    const pumped = try t.pump(fake.wall(), fake.now_ns + 4_000_000);
    try std.testing.expect(pumped.finished != null);
    try std.testing.expectEqual(ticket, pumped.finished.?.ticket);
    try std.testing.expectEqualStrings("history_start", @tagName(pumped.finished.?.ended.stop));
}

test "cancelling a reverse-continue restores the origin checkpoint" {
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
    try countFixture(&opened);
    try session.setRunBudget(.cpu0, 4096);
    _ = try session.run(.cpu0, .run);
    const str_addr = ra8.chip.core.memmap.sram_base + 0x6004;
    _ = try session.setBreakpoint(.cpu0, .{ .address = str_addr });
    _ = try session.run(.cpu0, .cont);
    _ = try session.run(.cpu0, .cont);

    var state = TestBridge{ .gpa = gpa, .opened = &opened, .sink = &sink, .objects = &objects };
    defer state.deinit();
    var t = transport.Transport{ .session = session };
    t.history = state.bridge();

    const cursor = session.grid.?.at;
    var fake = FakeWall{};
    const ticket = try t.command(.rcont);
    _ = try t.command(.pause);
    try std.testing.expectError(error.Cancelled, t.finish(ticket, fake.wall(), null));

    // The machine sits at the origin checkpoint again: the checkpoint
    // the job queued at, not wherever its replay had reached.
    const gathered = try seek_facts_mod.gather(gpa, sink.bytes.items);
    defer gpa.free(gathered.checkpoints);
    const plan = switch (seek_engine_mod.backBase(cursor, .{ .current = cursor, .checkpoints = gathered.checkpoints })) {
        .plan => |plan| plan,
        .pending => return error.TestUnexpectedResult,
    };
    const landed = session.grid.?.at;
    try std.testing.expect((try position_mod.compare(landed, plan.base.checkpoint.position)) == .eq);
}
