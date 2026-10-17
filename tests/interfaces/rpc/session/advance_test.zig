//! RA8EMU-654 through the serve handler on a real board: `advance` runs
//! board time forward by a duration, exactly, and stops early on a break.
//! It also carries RA8EMU-767's end-to-end check: the RA8EMU-655 sleeper
//! (idler.zig with SysTick reloaded to one ten-minute period at 25 kHz)
//! sleeps ten virtual minutes through a session in under a host second.
const std = @import("std");
const ra8 = @import("ra8");
const idler = @import("../../cli/idler.zig");
const store_board = @import("../../cli/store_board.zig");

const memmap = ra8.chip.core.memmap;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const GuestBus = ra8.chip.core.cpu.memory.guest.bus.GuestBus;
const NvicSource = ra8.chip.core.cpu.exception.nvic_source.NvicSource;
const Machine = ra8.session.stop_machine.Machine;
const api = ra8.session.api;
const BoardBoundary = ra8.session.board.boundary.BoardBoundary;
const server = ra8.rpc.session.server;
const advance = ra8.rpc.session.advance;
const Harness = ra8.session.harness.Harness;
const Cpu1 = ra8.session.cpu1.bringup.Cpu1;
const proto = ra8.rpc.session.rpc;
const rig_mod = @import("advance_rig.zig");
const Rig = rig_mod.Rig;
const FakeWall = rig_mod.FakeWall;
const Seen = rig_mod.Seen;
const cycle_ns = rig_mod.cycle_ns;
const failingTick = rig_mod.failingTick;
const hz = rig_mod.hz;
const period = rig_mod.period;
const ns_per_s = rig_mod.ns_per_s;

// The first wake lands at the start (idler.zig arms SysTick with CVR at
// zero), so the second is due ten virtual minutes later.
test "advance sleeps ten virtual minutes, wakes on time, in under a host second" {
    var rig: Rig = .{};
    try rig.open();
    defer rig.close();
    const first = try rig.advanceBy(ns_per_s);
    try std.testing.expectEqual(@as(u64, 0), first.from_ns);
    try std.testing.expectEqual(ns_per_s, first.to_ns);
    try std.testing.expectEqual(proto.StopReason.count, first.reason);
    const baseline = try rig.wakes();

    const started = std.Io.Timestamp.now(std.testing.io, .awake);
    const short = try rig.advanceBy(598 * ns_per_s);
    try std.testing.expect(started.durationTo(std.Io.Timestamp.now(std.testing.io, .awake)).toNanoseconds() < ns_per_s);
    try std.testing.expectEqual(599 * ns_per_s, short.to_ns);
    try std.testing.expectEqual(short.to_ns, try rig.session.now());
    try std.testing.expectEqual(baseline, try rig.wakes());

    const over = try rig.advanceBy(2 * ns_per_s);
    try std.testing.expectEqual(601 * ns_per_s, over.to_ns);
    try std.testing.expectEqual(baseline + 1, try rig.wakes());
    try std.testing.expectEqual(@as(u64, 1000), rig.session.live.budget);
}

test "a breakpoint ends an advance early, at the time it reached" {
    var rig: Rig = .{};
    try rig.open();
    defer rig.close();
    _ = try rig.advanceBy(ns_per_s);
    _ = try rig.machine.addBreak(.{ .address = idler.handler_at });
    const moved = try rig.advanceBy(600 * ns_per_s);
    try std.testing.expectEqual(proto.StopReason.breakpoint, moved.reason);
    try std.testing.expectEqual(idler.handler_at, moved.address);
    try std.testing.expect(moved.to_ns < moved.from_ns + 600 * ns_per_s);
    try std.testing.expect(moved.to_ns > moved.from_ns);
    try std.testing.expectEqual(moved.to_ns, try rig.session.now());
    try std.testing.expectEqual(@as(u64, 1000), rig.session.live.budget);
    try std.testing.expect(rig.context.pending != null);
}

test "a zero duration is refused as bad arguments" {
    var rig: Rig = .{};
    try rig.open();
    defer rig.close();
    const outcome = advance.advance(&rig.context, .{ .core = .cpu0, .ns = 0 });
    try std.testing.expect(outcome == .err);
}

// One cycle, then three: each reply is the session's time, while the board's
// own clock waits for the stretch to close.
test "an advance inside an open stretch moves by its duration and leaves the board unticked" {
    var rig: Rig = .{};
    try rig.open();
    defer rig.close();
    const one = try rig.advanceBy(cycle_ns);
    try std.testing.expectEqual(@as(u64, 0), one.from_ns);
    try std.testing.expectEqual(cycle_ns, one.to_ns);
    const closed = rig.board.time.base.now();
    const three = try rig.advanceBy(3 * cycle_ns);
    try std.testing.expectEqual(one.to_ns, three.from_ns);
    try std.testing.expectEqual(4 * cycle_ns, three.to_ns);
    const at = try rig.seen();
    try std.testing.expectEqual(closed, at.closed_ns);
    try std.testing.expect(at.carry != 0);
    try std.testing.expect(at.closed_ns < at.now_ns);
    try std.testing.expectEqual(at.now_ns, rig.board.time.base.nowAfter(at.carry));
    try std.testing.expectEqual(three.to_ns, at.now_ns);
}

test "split advances leave the guest, the time and the stretch where one advance does" {
    var whole: Rig = .{};
    try whole.open();
    defer whole.close();
    var parts: Rig = .{};
    try parts.open();
    defer parts.close();
    // The 599 s step crosses the wake at ten minutes, which closes a stretch.
    const steps = [_]u64{ cycle_ns, 3 * cycle_ns, ns_per_s, 12_496 * cycle_ns, 599 * ns_per_s, ns_per_s };
    var total: u64 = 0;
    for (steps) |step| {
        const moved = try parts.advanceBy(step);
        try std.testing.expectEqual(total, moved.from_ns);
        try std.testing.expectEqual(total + step, moved.to_ns);
        try std.testing.expectEqual(proto.StopReason.count, moved.reason);
        total += step;
    }
    const once = try whole.advanceBy(total);
    try std.testing.expectEqual(total, once.to_ns);
    const left = try whole.seen();
    // The advance crossed a close and ended inside a stretch, so both clocks are in play.
    try std.testing.expect(left.closed_ns != 0);
    try std.testing.expect(left.carry != 0);
    try std.testing.expect(left.closed_ns < left.now_ns);
    try std.testing.expectEqual(left, try parts.seen());
}

// 30 kHz has no whole number of nanoseconds per cycle.
test "a fractional cycle period lands on the first cycle at or past the target" {
    var rig: Rig = .{};
    try rig.open();
    defer rig.close();
    rig.board.time.base.setRate(30_000);
    var at: u64 = 0;
    for (0..5) |_| {
        const moved = try rig.advanceBy(50_000);
        try std.testing.expectEqual(at, moved.from_ns);
        try std.testing.expect(moved.to_ns >= moved.from_ns + 50_000);
        try std.testing.expect(moved.to_ns - moved.from_ns - 50_000 < 33_334);
        try std.testing.expectEqual(moved.to_ns, try rig.session.now());
        at = moved.to_ns;
    }
    try std.testing.expectEqual(@as(u64, 333_333), at);
}

test "a break mid-advance reports the position a plain run reaches" {
    var served: Rig = .{};
    try served.open();
    defer served.close();
    var plain: Rig = .{};
    try plain.open();
    defer plain.close();
    _ = try served.advanceBy(ns_per_s);
    _ = try plain.advanceBy(ns_per_s);
    _ = try served.machine.addBreak(.{ .address = idler.handler_at });
    _ = try plain.machine.addBreak(.{ .address = idler.handler_at });
    const moved = try served.advanceBy(700 * ns_per_s);
    try std.testing.expectEqual(proto.StopReason.breakpoint, moved.reason);
    try plain.session.setRunBudget(.cpu0, 700 * hz);
    try std.testing.expect(try plain.session.run(.cpu0, .cont) == .stop);
    try plain.session.setRunBudget(.cpu0, 1000);
    const at = try served.seen();
    try std.testing.expectEqual(moved.to_ns, at.now_ns);
    try std.testing.expectEqual(idler.handler_at, at.pc);
    try std.testing.expectEqual(try plain.seen(), at);
}

test "an advance the board refuses gives the run budget back" {
    var rig: Rig = .{};
    try rig.open();
    defer rig.close();
    rig.session.live.boundary.?.tickFn = failingTick;
    // Inside the first stretch nothing ticks, so nothing fails.
    const inside = try rig.advanceBy(cycle_ns);
    try std.testing.expectEqual(cycle_ns, inside.to_ns);
    const outcome = advance.advance(&rig.context, .{ .core = .cpu0, .ns = 700 * ns_per_s });
    try std.testing.expect(outcome == .err);
    try std.testing.expectEqual(@as(u64, 1000), rig.session.live.budget);
}

// This board has no second core paired, so the parked core cannot run: the
// refusal comes back after the adapter has switched to it and set a budget.
test "an advance on a parked core the board cannot run is refused with both budgets kept" {
    var rig: Rig = .{};
    try rig.open();
    defer rig.close();
    try rig.park(77);
    const first = try rig.advanceCore(.cpu0, 5 * cycle_ns);
    try std.testing.expectEqual(5 * cycle_ns, first.to_ns);
    try std.testing.expectEqual(@as(u64, 77), rig.session.live.other.?.budget);
    const outcome = advance.advance(&rig.context, .{ .core = .cpu1, .ns = 7 * cycle_ns });
    try std.testing.expect(outcome == .err);
    try std.testing.expectEqual(first.to_ns, try rig.session.now());
    try std.testing.expectEqual(@as(u8, 1), rig.session.live.index);
    try std.testing.expectEqual(@as(u64, 77), rig.session.live.budget);
    try std.testing.expectEqual(@as(u64, 1000), rig.session.live.other.?.budget);
    const back = try rig.advanceCore(.cpu0, ns_per_s);
    try std.testing.expectEqual(first.to_ns, back.from_ns);
    try std.testing.expectEqual(5 * cycle_ns + ns_per_s, back.to_ns);
    try std.testing.expectEqual(@as(u64, 1000), rig.session.live.budget);
    try std.testing.expectEqual(@as(u64, 77), rig.session.live.other.?.budget);
}

const dual_cpu0 = "tests/fixtures/trustzone/cpu1_pingpong_ipc.elf";
const dual_cpu1 = "tests/fixtures/trustzone/cpu1_pingpong_ipc_cpu1.elf";

/// The real dual IPC corpus (concrete CPU0 and CPU1 images) behind an RPC context.
const Dual = struct {
    second: Cpu1 = .{},
    harness: Harness = undefined,
    scratch: [64]u8 = undefined,
    context: server.Context = undefined,

    fn open(self: *Dual) !void {
        self.harness = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = dual_cpu0 });
        errdefer self.harness.deinit();
        try self.second.open(std.testing.allocator, std.testing.io, std.Io.Dir.cwd(), &self.harness, dual_cpu1);
        self.harness.state.edge.idle_skip = false;
        self.context = .{ .session = self.harness.session(), .scratch = &self.scratch };
    }

    fn close(self: *Dual) void {
        self.second.close(std.testing.allocator);
        self.harness.deinit();
    }

    fn retired(self: *Dual, which: api.Core) u64 {
        return if (which == .cpu0) self.harness.primaryCpu().retired else self.second.cpu().retired;
    }

    fn pc(self: *Dual, which: api.Core) u32 {
        return if (which == .cpu0) self.harness.primaryCpu().regs.pc else self.second.cpu().regs.pc;
    }
};

/// Break `winner` at `at` while `asked` is the core the advance names, then
/// check the reply against what a plain run of the same budget leaves.
fn winnerStops(asked: api.Core, winner: api.Core, at: u32) !void {
    var rpc: Dual = .{};
    try rpc.open();
    defer rpc.close();
    var plain: Dual = .{};
    try plain.open();
    defer plain.close();
    _ = try rpc.harness.session().setBreakpoint(winner, .{ .address = at });
    _ = try plain.harness.session().setBreakpoint(winner, .{ .address = at });

    const ns = ns_per_s / 100;
    const moved = switch (advance.advance(&rpc.context, .{ .core = @fromBackingInt(@intCast(@backingInt(asked))), .ns = ns })) {
        .ok => |reply| reply,
        .err => return error.Refused,
    };
    const budget = plain.harness.session().time_base.?.cyclesUntil(ns);
    try plain.harness.session().setRunBudget(asked, budget);
    const ended = try plain.harness.session().run(asked, .cont);
    try std.testing.expect(ended == .stop and ended.stop == .breakpoint);

    const ended_index = rpc.harness.session().live.ended_index;
    try std.testing.expectEqual(@backingInt(winner), ended_index);
    try std.testing.expectEqual(plain.harness.session().live.ended_index, ended_index);
    try std.testing.expectEqual(proto.StopReason.breakpoint, moved.reason);
    // The stop the server publishes and the reply both name the winner.
    try std.testing.expectEqual(@backingInt(winner), @backingInt(moved.core));
    try std.testing.expectEqual(@backingInt(winner), @backingInt(rpc.context.pending.?.core));
    try std.testing.expectEqual(at, rpc.context.pending.?.address);
    try std.testing.expectEqual(at, moved.address);
    try std.testing.expectEqual(at, rpc.pc(winner));
    try std.testing.expect(moved.to_ns > moved.from_ns and moved.to_ns < ns);
    try std.testing.expect(rpc.retired(winner) > 0);
    // Nothing ran past the win: both cores and the clock stand where the plain run left them.
    try std.testing.expectEqual(try plain.harness.session().now(), moved.to_ns);
    for ([_]api.Core{ .cpu0, .cpu1 }) |which| {
        try std.testing.expectEqual(plain.retired(which), rpc.retired(which));
        try std.testing.expectEqual(plain.pc(which), rpc.pc(which));
    }
    std.debug.print("CHECK=winner asked={s} winner={s} reply={s} ended_index={d} to_ns={d} retired0={d} retired1={d}\n", .{ @tagName(asked), @tagName(winner), @tagName(moved.core), ended_index, moved.to_ns, rpc.retired(.cpu0), rpc.retired(.cpu1) });
}

test "an advance asked of CPU0 that CPU1 breaks reports CPU1 at its position" {
    var probe: Dual = .{};
    try probe.open();
    defer probe.close();
    try probe.harness.session().setRunBudget(.cpu0, 125_987);
    _ = try probe.harness.session().run(.cpu0, .cont);
    try winnerStops(.cpu0, .cpu1, probe.pc(.cpu1));
}

test "an advance asked of CPU1 that CPU0 breaks reports CPU0 at its position" {
    var probe: Dual = .{};
    try probe.open();
    defer probe.close();
    try probe.harness.session().setRunBudget(.cpu0, 50_000);
    _ = try probe.harness.session().run(.cpu0, .cont);
    try winnerStops(.cpu1, .cpu0, probe.pc(.cpu0));
}

test "advance through the transport answers the same reply" {
    var legacy = Rig{};
    try legacy.open();
    defer legacy.close();
    const straight = try legacy.advanceBy(period);

    var through = Rig{};
    try through.open();
    defer through.close();
    var plane = ra8.session.transport.Transport{ .session = &through.session };
    through.context.transport = &plane;
    var wall = FakeWall{};
    through.context.wall = .{ .context = &wall, .nowFn = FakeWall.now };
    const routed = try through.advanceBy(period);

    try std.testing.expectEqual(straight.from_ns, routed.from_ns);
    try std.testing.expectEqual(straight.to_ns, routed.to_ns);
    try std.testing.expectEqual(straight.reason, routed.reason);
    try std.testing.expectEqual(straight.address, routed.address);
}

test "an async advance queues and completes on the transport" {
    var rig = Rig{};
    try rig.open();
    defer rig.close();
    var plane = ra8.session.transport.Transport{ .session = &rig.session };
    rig.context.transport = &plane;
    var wall = FakeWall{};
    rig.context.wall = .{ .context = &wall, .nowFn = FakeWall.now };
    rig.context.transport_async = true;

    const queued = queuedBy(&rig.context, .{ .core = .cpu0, .ns = period }) orelse return error.Refused;
    const from = try rig.session.now();
    try std.testing.expectEqual(from, queued.from_ns);
    try std.testing.expectEqual(from + period, queued.target_ns);
    const ticket = rig.context.advance_ticket orelse return error.NoTicket;

    // The plane is on the job before any pump, and nothing has run yet.
    try std.testing.expectEqual(ra8.session.transport.Phase.advancing, plane.report().phase);
    try std.testing.expectEqual(from, try rig.session.now());

    // Host.poll's bounded pumps drive it to the target and the completion
    // is the queueing connection's ticket.
    // One window per pump: the wall read inside `drive` consumes the first
    // millisecond, so the deadline needs a margin over the pre-read value.
    while (plane.job != null and wall.ns < 60_000_000_000) {
        _ = try plane.pump(.{ .context = &wall, .nowFn = FakeWall.now }, wall.ns + 2_000_000);
    }
    const done = plane.done orelse return error.NoFinish;
    try std.testing.expectEqual(ticket, done.ticket);
    try std.testing.expectEqual(from + period, try rig.session.now());
    try std.testing.expect(rig.context.advance_ticket != null); // still owed until poll sends it
}

test "advance_async refuses without the plane or the flag" {
    var rig = Rig{};
    try rig.open();
    defer rig.close();
    try std.testing.expect(queuedBy(&rig.context, .{ .core = .cpu0, .ns = period }) == null);
    var plane = ra8.session.transport.Transport{ .session = &rig.session };
    rig.context.transport = &plane;
    var wall = FakeWall{};
    rig.context.wall = .{ .context = &wall, .nowFn = FakeWall.now };
    // The plane without the async flag refuses too: `serve` keeps the
    // blocking contract.
    try std.testing.expect(queuedBy(&rig.context, .{ .core = .cpu0, .ns = period }) == null);
    try std.testing.expect(plane.job == null);
}

/// The queued reply, or null when the handler refused.
fn queuedBy(context: *server.Context, args: proto.Advance) ?proto.AdvanceQueued {
    return switch (advance.advanceQueued(context, args)) {
        .ok => |moved| moved,
        .err => null,
    };
}
