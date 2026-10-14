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

/// Built with debug info, so the session has an image to read locals from.
const debug_image = "tests/fixtures/threadx/threadx_stkof.elf";

/// A shell whose only leaf is the locals pair, on a greeted link with no
/// image loaded yet: whatever reaches the pair got there through the shell.
const LocalsBench = struct {
    rig: Rig,
    shell: Shell,
    locals: gui.shell.locals.Pair = .{},

    fn open(self: *LocalsBench) !void {
        self.* = .{ .rig = undefined, .shell = undefined };
        try self.rig.open(debug_image);
        errdefer self.rig.deinit();
        self.shell = Shell.init(std.testing.allocator, try gui.pane_layout.twoCore(std.testing.allocator));
        self.shell.link = &self.rig.link;
        self.shell.locals = &self.locals;
    }

    fn deinit(self: *LocalsBench) void {
        self.shell.deinit();
        self.rig.deinit();
    }

    /// Let the session answer, then take what it sent through the shell.
    fn round(self: *LocalsBench) !void {
        try self.rig.session.answer();
        try self.shell.pump();
    }

    /// Send the image and stop on the round its load is answered.
    fn load(self: *LocalsBench) !void {
        const gpa = std.testing.allocator;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, debug_image, gpa, .limited(1 << 20));
        defer gpa.free(bytes);
        try self.shell.status.load(&self.rig.link, debug_image, bytes);
        for (0..32) |_| {
            try self.round();
            if (self.shell.loaded) return;
        }
        return error.NeverLoaded;
    }

    /// Rounds until cpu0's due ask has gone out and been answered.
    fn shown(self: *LocalsBench) !void {
        const model = &self.locals.cores[0];
        for (0..8) |_| {
            if (!model.want and model.asked == null) return;
            try self.round();
        }
        return error.NeverAnswered;
    }
};

/// The leaf has an ask due, out or answered.
fn touched(model: *const gui.shell.locals.Locals) bool {
    return model.want or model.asked != null or model.now != null or model.refused;
}

test "a load answered through the shell makes each locals leaf ask, and the answer is shown" {
    var bench: LocalsBench = undefined;
    try bench.open();
    defer bench.deinit();
    const cpu0 = &bench.locals.cores[0];
    const cpu1 = &bench.locals.cores[1];
    // No image yet: nothing is due, so nothing is asked.
    try bench.round();
    try std.testing.expect(!touched(cpu0) and !touched(cpu1));
    try bench.load();
    // The load's answer starts both leaves over.
    try std.testing.expect(cpu0.want and cpu1.want);
    try std.testing.expectEqual(@as(?u32, null), cpu0.asked);
    // The next pump sends the due ask.
    try bench.shell.pump();
    try std.testing.expect(!cpu0.want and cpu0.asked != null);
    // Its answer becomes the rows the pane draws.
    try bench.round();
    try std.testing.expectEqual(@as(?u32, null), cpu0.asked);
    try std.testing.expect(cpu0.now != null);
    try std.testing.expectEqual(@as(?[]const u8, null), cpu0.note());
}

test "a Step's stop asks cpu0's locals again and leaves cpu1's alone" {
    var bench: LocalsBench = undefined;
    try bench.open();
    defer bench.deinit();
    const cpu0 = &bench.locals.cores[0];
    const cpu1 = &bench.locals.cores[1];
    try bench.load();
    try bench.shown();
    try std.testing.expect(cpu0.now != null and !cpu1.want);
    _ = try bench.rig.link.send(proto.Run, .run, .{ .core = .cpu0, .mode = .step, .budget = 0 });
    try bench.round();
    try std.testing.expect(cpu0.want and !cpu1.want);
    try bench.shell.pump();
    try std.testing.expect(cpu0.asked != null);
    try bench.shown();
    try std.testing.expect(cpu0.now != null);
}

test "a settled Pause walks both cores' locals again" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.deinit();
    var locals: gui.shell.locals.Pair = .{};
    bench.shell.locals = &locals;
    try bench.fill();
    try execution.paySlices(&bench.shell, .fresh);
    // The bench loaded the image behind the shell's back, and a slice is not a stop.
    for (&locals.cores) |*model| try std.testing.expect(!touched(model));
    bench.time.pressCommand(.pause, &bench.rig.link, &bench.shell.status);
    try execution.paySlices(&bench.shell, .fresh);
    try bench.rig.session.answer();
    try execution.exchange(&bench.shell);
    try execution.paySlices(&bench.shell, .fresh);
    try std.testing.expect(!bench.time.run.lit);
    // A pause has no stop event of cpu1's: only the settled halt makes its ask due.
    for (&locals.cores) |*model| try std.testing.expect(touched(model));
}
