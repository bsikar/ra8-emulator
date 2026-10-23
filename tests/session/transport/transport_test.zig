//! Transport tests: a command queues without running, the pump is bounded by
//! the wall, the newest command preempts, pause stops at the gap, a
//! malformed or backward play is refused unchanged, an advance reaches its
//! virtual target, a firing poll interrupts and settles, pause-then-play
//! is byte-identical to never pausing, and the read gate reports busy{state}
//! only while a job is actually moving.

const std = @import("std");
const ra8 = @import("ra8");
const transport = ra8.session.transport;

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

/// Where the machine stands: virtual time, the counter word, and the PC.
const Mark = struct { ns: u64, counter: u32, pc: u32 };

fn mark(opened: *ra8.session.harness.Harness) !Mark {
    return .{
        .ns = try opened.session().now(),
        .counter = try opened.guest().readWord(counter_addr),
        .pc = opened.primaryCpu().regs.pc,
    };
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

test "command queues a job and runs nothing" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image_path });
    defer opened.deinit();
    var t = transport.Transport{ .session = opened.session() };
    const before = try opened.session().now();
    const ticket = try t.command(.{ .cont = .{} });
    try std.testing.expectEqual(@as(transport.Ticket, 1), ticket);
    try std.testing.expectEqual(before, try opened.session().now());
    const report = t.report();
    try std.testing.expectEqual(@as(u64, 1), report.epoch);
    try std.testing.expectEqual(transport.Phase.continuing, report.phase);
    try std.testing.expect(report.position == null); // no run yet, no position
}

test "the report carries the running job's state payloads" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image_path });
    defer opened.deinit();
    var t = transport.Transport{ .session = opened.session() };
    try std.testing.expect(t.report().state == null); // nothing queued yet
    _ = try t.command(.{ .cont = .{} });
    try std.testing.expectEqual(@as(transport.State, .{ .continuing = .{ .dir = .fwd } }), t.report().state.?);
    _ = try t.command(.{ .step = .{ .core = .cpu0, .count = 3 } });
    try std.testing.expectEqual(@as(transport.State, .{ .stepping = .{ .core = .cpu0, .count = 3, .dir = .fwd } }), t.report().state.?);
    _ = try t.command(.{ .play = .{ .speed = 2.5 } });
    try std.testing.expectEqual(@as(transport.State, .{ .playing = .{ .dir = .fwd, .speed = 2.5 } }), t.report().state.?);
    _ = try t.command(.pause);
    try std.testing.expect(t.report().state == null);
}

test "reads are quiet until a job actually moves" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image_path });
    defer opened.deinit();
    var t = transport.Transport{ .session = opened.session() };
    try std.testing.expect(t.busy() == null); // nothing queued yet
    _ = try t.command(.{ .cont = .{} });
    try std.testing.expect(t.busy() == null); // queued, but its first pump has not run
}

test "reads return the running job's state while it moves" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image_path });
    defer opened.deinit();
    try loopFixture(&opened);
    var fake = FakeWall{};
    var t = transport.Transport{ .session = opened.session() };
    _ = try t.command(.{ .cont = .{} });
    _ = try t.pump(fake.wall(), fake.now_ns + 4_000_000);
    try std.testing.expectEqual(@as(transport.State, .{ .continuing = .{ .dir = .fwd } }), t.busy().?);
    try std.testing.expectEqual(transport.Phase.continuing, t.report().phase);
    _ = try t.command(.pause);
    try std.testing.expect(t.busy() == null); // the pause drops the job at once; the machine is parked at the gap
    _ = try t.pump(fake.wall(), fake.now_ns + 4_000_000);
    try std.testing.expect(t.busy() == null);
}

test "a paced play drives bounded slices and outlives the wall" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image_path });
    defer opened.deinit();
    try loopFixture(&opened);
    var fake = FakeWall{};
    var t = transport.Transport{ .session = opened.session() };
    _ = try t.command(.{ .play = .{ .speed = 0.001 } });
    const pumped = try t.pump(fake.wall(), fake.now_ns + 8_000_000);
    try std.testing.expect(pumped.finished == null);
    try std.testing.expect(pumped.report.progress.slices >= 1);
    try std.testing.expectEqual(transport.Phase.playing, pumped.report.phase);
}

test "pause stops at the gap and the machine goes nowhere after" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image_path });
    defer opened.deinit();
    try loopFixture(&opened);
    var fake = FakeWall{};
    var t = transport.Transport{ .session = opened.session() };
    _ = try t.command(.{ .cont = .{} });
    _ = try t.pump(fake.wall(), fake.now_ns + 4_000_000);
    _ = try t.command(.pause);
    const held = try opened.session().now();
    const pumped = try t.pump(fake.wall(), fake.now_ns + 100_000_000);
    try std.testing.expectEqual(transport.Phase.halted, pumped.report.phase);
    try std.testing.expectEqual(held, try opened.session().now());
}

test "the newest command preempts the running job" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image_path });
    defer opened.deinit();
    try loopFixture(&opened);
    var fake = FakeWall{};
    var t = transport.Transport{ .session = opened.session() };
    const first = try t.command(.{ .cont = .{} });
    _ = try t.pump(fake.wall(), fake.now_ns + 4_000_000);
    const second = try t.command(.{ .step = .{ .core = .cpu0, .count = 2 } });
    try std.testing.expect(second > first);
    try std.testing.expectError(transport.Error.Cancelled, t.finish(first, fake.wall(), null));
    const pumped = try t.pump(fake.wall(), fake.now_ns + 4_000_000);
    try std.testing.expect(pumped.finished != null);
    try std.testing.expectEqual(second, pumped.finished.?.ticket);
}

test "a malformed or backward play is refused and changes nothing" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image_path });
    defer opened.deinit();
    var t = transport.Transport{ .session = opened.session() };
    _ = try t.command(.{ .cont = .{} });
    const epoch = t.report().epoch;
    const phase = t.report().phase;
    try std.testing.expectError(transport.Error.InvalidSpeed, t.command(.{ .play = .{ .speed = 0 } }));
    try std.testing.expectError(transport.Error.NotReady, t.command(.{ .play = .{ .dir = .back } }));
    // An empty target and any unparsable one are refused at the door;
    // a well-formed one is still refused with NotReady, its drive pending.
    try std.testing.expectError(transport.Error.InvalidArgs, t.command(.{ .seek = .{} }));
    try std.testing.expectError(transport.Error.InvalidArgs, t.command(.{ .seek = .{ .target = "nope" } }));
    try std.testing.expectError(transport.Error.NotReady, t.command(.{ .seek = .{ .target = "3:cpu1:4:polled" } }));
    try std.testing.expectError(transport.Error.NotReady, t.command(.{ .seek = .{ .target = "2:3:cpu0:1:retired" } }));
    try std.testing.expectEqual(epoch, t.report().epoch);
    try std.testing.expectEqual(phase, t.report().phase);
}

test "advance runs to its virtual target and finishes its ticket" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image_path });
    defer opened.deinit();
    try loopFixture(&opened);
    var fake = FakeWall{};
    var t = transport.Transport{ .session = opened.session() };
    const target = (try opened.session().now()) + 64;
    const ticket = try t.command(.{ .advance = .{ .core = .cpu0, .ns = 64 } });
    const pumped = try t.pump(fake.wall(), fake.now_ns + 64_000_000);
    try std.testing.expectEqual(target, try opened.session().now());
    try std.testing.expect(pumped.report.position != null);
    try std.testing.expect(pumped.finished != null);
    try std.testing.expectEqual(ticket, pumped.finished.?.ticket);
}

test "pause then play equals never pausing" {
    // Straight: twelve slices in three wall-bounded pumps, then pause.
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image_path });
    defer opened.deinit();
    try countFixture(&opened);
    var fake = FakeWall{};
    var t = transport.Transport{ .session = opened.session() };
    _ = try t.command(.{ .cont = .{} });
    for (0..3) |_| _ = try t.pump(fake.wall(), fake.now_ns + 4_000_000);
    _ = try t.command(.pause);
    _ = try t.pump(fake.wall(), fake.now_ns + 4_000_000);
    const straight = try mark(&opened);

    // Interrupted: four slices, pause at the gap, play on for eight more,
    // then pause again. The Stage 0 oracle in miniature: the guest counter,
    // the virtual time and the PC must land exactly where the straight run
    // left them.
    var reopened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image_path });
    defer reopened.deinit();
    try countFixture(&reopened);
    var fake2 = FakeWall{};
    var t2 = transport.Transport{ .session = reopened.session() };
    _ = try t2.command(.{ .cont = .{} });
    _ = try t2.pump(fake2.wall(), fake2.now_ns + 4_000_000);
    _ = try t2.command(.pause);
    _ = try t2.pump(fake2.wall(), fake2.now_ns + 4_000_000);
    _ = try t2.command(.{ .cont = .{} });
    for (0..2) |_| _ = try t2.pump(fake2.wall(), fake2.now_ns + 4_000_000);
    _ = try t2.command(.pause);
    _ = try t2.pump(fake2.wall(), fake2.now_ns + 4_000_000);
    const interrupted = try mark(&reopened);

    try std.testing.expectEqual(straight.ns, interrupted.ns);
    try std.testing.expectEqual(straight.counter, interrupted.counter);
    try std.testing.expectEqual(straight.pc, interrupted.pc);
}
