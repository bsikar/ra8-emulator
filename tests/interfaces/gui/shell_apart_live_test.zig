//! The shell loop over a session on a thread of its own
//! (src/interfaces/gui/session_worker.zig), on a headless window with the
//! host's clock: the image loads, Run moves board time while every frame
//! still presents, and Pause settles on the core's halt.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");

const proto = ra8.rpc.session.rpc;
const Env = proto.Client.Env;
const Headless = gui_app.headless.Headless;

/// Blinks LED1 twice and then parks in a loop, so it never stops by itself.
const image = "tests/fixtures/gpio/blink.elf";
/// The bar's speed, in thousandths of real time: the image runs a 1 GHz
/// clock, which the session cannot keep up with.
const slow: u64 = 1;
/// Frames a wait may take before the test calls it lost.
const patience: usize = 20_000;

const Apart = struct {
    session: gui_app.local_session.LocalSession,
    worker: gui_app.session_worker.Worker,
    host_clock: gui_app.wall_clock.Host,
    rx: []u8,
    tx: []u8,
    link: gui_app.session_link.Link,
    shell: gui_app.shell.loop.Shell,
    window: Headless,
    time: gui_app.shell.time.Time,

    /// Opens in place and runs frames until `image` has loaded and halted.
    fn open(self: *Apart) !void {
        const gpa = std.testing.allocator;
        const io = std.testing.io;
        try self.session.open(gpa, io, image, null);
        self.host_clock = .init(io);
        self.rx = try gpa.alloc(u8, 2 * Env.max_frame);
        self.tx = try gpa.alloc(u8, Env.max_frame);
        self.link.open(self.worker.bind(io, gpa, &self.session, self.host_clock.clock()), self.rx, self.tx);
        self.shell = .init(gpa, try gui_app.pane_layout.twoCore(gpa));
        self.window = .init(gpa, 640, 480);
        self.time = .{};
        self.time.field.applied = slow;
        self.shell.link = &self.link;
        self.shell.clock = self.host_clock.clock();
        self.shell.time = &self.time;
        try self.worker.serveShell(&self.shell);
        try self.until(connected);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, image, gpa, .limited(1 << 20));
        defer gpa.free(bytes);
        try self.shell.status.load(&self.link, image, bytes);
        try self.until(halted);
    }

    fn deinit(self: *Apart) void {
        const gpa = std.testing.allocator;
        self.worker.deinit();
        self.window.deinit();
        self.shell.deinit();
        gpa.free(self.tx);
        gpa.free(self.rx);
        self.session.deinit();
    }

    /// One frame, then the time to the next the way ra8_gui spends it:
    /// asleep until the session answers, and awake to take what it sent.
    fn frame(self: *Apart) !void {
        const presents = self.window.presents;
        try std.testing.expect(try self.shell.step(self.window.platform()));
        try std.testing.expectEqual(presents + 1, self.window.presents);
        if (self.worker.wait(std.time.ns_per_ms)) try self.shell.service();
    }

    fn until(self: *Apart, comptime reached: fn (*const Apart) bool) !void {
        for (0..patience) |_| {
            if (reached(self)) return;
            try self.frame();
        }
        return error.NeverReached;
    }

    fn connected(self: *const Apart) bool {
        return self.link.state == .connected;
    }

    fn halted(self: *const Apart) bool {
        return self.shell.status.run == .halted and !self.time.run.lit and self.time.run.slice_id == null;
    }

    fn moved(self: *const Apart) bool {
        return self.time.boardNow() != 0;
    }
};

test "the shell serves nothing itself: its session answers on the worker's thread" {
    var apart: Apart = undefined;
    try apart.open();
    defer apart.deinit();
    try std.testing.expect(apart.shell.worker == &apart.worker);
    try std.testing.expect(apart.shell.listener == null);
    try std.testing.expect(apart.time.run.answered_at == &apart.worker.wire.answered_ns);
    try std.testing.expectEqual(@as(?u64, null), apart.time.run.board_ns);
}

test "Run moves board time while every frame presents, and Pause settles on the halt" {
    var apart: Apart = undefined;
    try apart.open();
    defer apart.deinit();
    const reset = apart.shell.status.run.halted.address;
    apart.time.pressCommand(.run, &apart.link, &apart.shell.status);
    try std.testing.expect(apart.time.run.lit);
    try apart.until(Apart.moved);
    try std.testing.expect(apart.shell.status.run == .running);
    apart.time.pressCommand(.pause, &apart.link, &apart.shell.status);
    try apart.until(Apart.halted);
    try std.testing.expect(apart.shell.status.run.halted.address != reset);
    const stopped_at = apart.time.run.board_ns.?;
    for (0..5) |_| try apart.frame();
    try std.testing.expectEqual(stopped_at, apart.time.run.board_ns.?);
}
