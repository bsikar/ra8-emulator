//! Session execution without drawing: queue pressure, recovery and settlement.
const std = @import("std");
const ra8 = @import("ra8");
const gui = @import("gui_app");
const Rig = @import("../local_rig.zig").Rig;
const Manual = @import("../manual_clock.zig").Manual;
const proto = ra8.rpc.session.rpc;
const execution = gui.shell.loop.execution;
const Shell = gui.shell.loop.Shell;

const image = "tests/fixtures/gpio/blink.elf";

const Bench = struct {
    rig: Rig,
    shell: Shell,
    time: gui.shell.time.Time = .{},
    manual: Manual = .{},

    fn open(self: *Bench) !void {
        self.* = .{ .rig = undefined, .shell = undefined };
        try self.rig.open(image);
        errdefer self.rig.deinit();
        self.shell = Shell.init(std.testing.allocator, try gui.pane_layout.twoCore(std.testing.allocator));
        errdefer self.shell.deinit();
        try self.rig.load(&self.shell.status, image);
        self.time.field.applied = 1;
        self.time.stale = false;
        self.time.run.start(self.shell.status.run.halted.address);
        self.shell.status.running();
        self.shell.link = &self.rig.link;
        self.shell.time = &self.time;
        self.shell.clock = self.manual.clock();
    }

    fn deinit(self: *Bench) void {
        self.shell.deinit();
        self.rig.deinit();
    }

    fn fill(self: *Bench) !void {
        for (0..proto.pending_slots) |_| _ = try self.rig.link.send(proto.Now, .now, .{ .core = .cpu0 });
    }
};

test "remote queued execution stays running and retries only after answers free capacity" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.deinit();
    try bench.fill();
    const at = bench.time.run.address;
    for (0..3) |_| {
        try execution.paySlices(&bench.shell, .fresh);
        try std.testing.expect(bench.time.run.lit and !bench.time.run.refused);
        try std.testing.expect(bench.shell.status.run == .running);
        try std.testing.expectEqual(@as(?gui.status.bar.Refusal, null), bench.shell.status.refused);
        try std.testing.expectEqual(@as(?u32, null), bench.time.run.slice_id);
        try std.testing.expectEqual(@as(?u32, null), bench.time.run.settled);
        try std.testing.expectEqual(at, bench.time.run.address);
    }
    try bench.rig.session.answer();
    try execution.exchange(&bench.shell);
    try std.testing.expect(bench.shell.drained);
    try execution.paySlices(&bench.shell, .fresh);
    const id = bench.time.run.slice_id orelse return error.NoRetry;
    // With the remote answer still unsettled, a later frame cannot send twice.
    try execution.paySlices(&bench.shell, .fresh);
    try std.testing.expectEqual(@as(?u32, id), bench.time.run.slice_id);
    try bench.rig.session.answer();
    try bench.shell.pump();
    try std.testing.expectEqual(@as(?u32, null), bench.time.run.slice_id);
    try std.testing.expect(bench.time.run.lit and !bench.time.run.refused);
    try std.testing.expect(bench.shell.status.run == .running);
    try std.testing.expect(bench.time.run.board_ns.? > 0);
}

test "a user Pause during queue pressure remains a halt after the queue drains" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.deinit();
    try bench.fill();
    try execution.paySlices(&bench.shell, .fresh);
    const at = bench.time.run.address;
    bench.time.pressCommand(.pause, &bench.rig.link, &bench.shell.status);
    try execution.paySlices(&bench.shell, .fresh);
    try std.testing.expectEqual(at, bench.shell.status.run.halted.address);
    try std.testing.expectEqual(@as(?gui.status.bar.Refusal, null), bench.shell.status.refused);
    try std.testing.expectEqual(@as(?u32, null), bench.time.run.halted());
    try bench.rig.session.answer();
    try execution.exchange(&bench.shell);
    try execution.paySlices(&bench.shell, .fresh);
    try std.testing.expect(!bench.time.run.lit and !bench.time.run.refused);
    try std.testing.expectEqual(@as(?u32, null), bench.time.run.slice_id);
    try std.testing.expectEqual(at, bench.shell.status.run.halted.address);
}

test "a genuine served slice refusal still settles the shell at its last address" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.deinit();
    bench.time.run.core = .cpu1;
    const at = bench.time.run.address;
    try execution.paySlices(&bench.shell, .fresh);
    try std.testing.expect(bench.time.run.slice_id != null);
    try bench.rig.session.answer();
    try execution.exchange(&bench.shell);
    try std.testing.expect(!bench.time.run.lit and bench.time.run.refused);
    try std.testing.expectEqual(at, bench.shell.status.run.halted.address);
    try std.testing.expectEqual(@as(?gui.status.bar.Refusal, .run), bench.shell.status.refused);
    try std.testing.expectEqual(@as(?u32, null), bench.time.run.halted());
}

const Listener = struct {
    calls: usize = 0,

    fn answer(ctx: *anyopaque) anyerror!void {
        const self: *Listener = @ptrCast(@alignCast(ctx));
        self.calls += 1;
    }
};

test "local execution drains the queued requests and answers each slice and listener" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.deinit();
    var listener: Listener = .{};
    bench.shell.server = gui.shell.server.served(&bench.rig.session);
    bench.shell.listener = .{ .context = &listener, .answerFn = Listener.answer };
    try bench.fill();
    try execution.exchange(&bench.shell);
    try std.testing.expectEqual(@as(usize, 1), listener.calls);
    try std.testing.expect(bench.shell.drained);
    try execution.paySlices(&bench.shell, .fresh);
    try std.testing.expectEqual(@as(usize, 2), listener.calls);
    try std.testing.expectEqual(@as(?u32, null), bench.time.run.slice_id);
    try std.testing.expectEqual(@as(?u64, 0), bench.time.run.owed_ns);
    try std.testing.expect(bench.time.run.lit and !bench.time.run.refused);
    try std.testing.expect(bench.shell.status.run == .running);
}
