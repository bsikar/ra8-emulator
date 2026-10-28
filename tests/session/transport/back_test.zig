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
const rig = @import("transport_rig.zig");

const FakeWall = rig.FakeWall;
const counter_addr = rig.counter_addr;
const countFixture = rig.countFixture;
const TestBridge = rig.TestBridge;
const history_elf = rig.history_elf;
const image_path = rig.image_path;

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

test "a reverse-continue is refused without a bridge" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image_path });
    defer opened.deinit();
    var t = transport.Transport{ .session = opened.session() };
    try std.testing.expectError(transport.Error.NotReady, t.command(.rcont));
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

test "a backward step outside window falls back to checkpoint replay and reports history_start only at real start" {
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

    const dummy_slot = ra8.session.history_window_engine.Slot{
        .pre = .{ .r = 0 },
        .post = session.grid.?.at,
        .core = .cpu0,
        .kind = .ram_cpu,
        .delta = .{},
        .digest = @splat(0),
    };
    var dummy_w: ra8.session.history_window_engine.ReverseWindow = undefined;
    dummy_w.trail.cursor = 0;
    dummy_w.slots = .empty;
    try dummy_w.slots.append(gpa, dummy_slot);
    defer dummy_w.slots.deinit(gpa);
    dummy_w.head = 0;
    dummy_w.image = .empty;
    dummy_w.hot = &.{};
    dummy_w.hot_at = null;
    dummy_w.planted_at = null;
    dummy_w.line = session.grid.?.at.branch;
    session.attachWindow(&dummy_w);

    var state = TestBridge{ .gpa = gpa, .opened = &opened, .sink = &sink, .objects = &objects };
    defer state.deinit();
    var t = transport.Transport{ .session = session };
    t.history = state.bridge();

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
}
