//! Tests for src/interfaces/gui/session_worker.zig: the local session
//! answers on a thread of its own, the shell only sends and takes frames,
//! and a stopped worker hands the session back.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const Manual = @import("manual_clock.zig").Manual;

const local_session = gui_app.local_session;
const session_link = gui_app.session_link;
const Worker = gui_app.session_worker.Worker;
const proto = ra8.rpc.session.rpc;
const Env = proto.Client.Env;

const image = "tests/fixtures/fpu/fp_basic.elf";
/// How long a test waits on the thread before it calls the answer lost.
const patience_ns: u64 = 5 * std.time.ns_per_s;

const Bench = struct {
    session: local_session.LocalSession = undefined,
    clock: Manual = .{ .now_ns = 1 },
    worker: Worker = undefined,
    link: session_link.Link = undefined,
    rx: []u8 = &.{},
    tx: []u8 = &.{},

    /// In place: the worker and the link point into `self`.
    fn open(self: *Bench) !void {
        const gpa = std.testing.allocator;
        try self.session.open(gpa, std.testing.io, image, null);
        errdefer self.session.deinit();
        self.rx = try gpa.alloc(u8, 2 * Env.max_frame);
        errdefer gpa.free(self.rx);
        self.tx = try gpa.alloc(u8, Env.max_frame);
        errdefer gpa.free(self.tx);
        self.worker.bind(std.testing.io, gpa, &self.session, self.clock.clock());
        self.link.openNative(&self.worker.native);
    }

    fn deinit(self: *Bench) void {
        self.worker.deinit();
        std.testing.allocator.free(self.tx);
        std.testing.allocator.free(self.rx);
        self.session.deinit();
    }

    /// Take arrivals until the link greets, waiting on the thread.
    fn greeted(self: *Bench) !void {
        while (self.link.state == .connecting) {
            if (self.link.pump() != null) continue;
            if (self.link.state != .connecting) break;
            if (!self.worker.wait(patience_ns)) return error.NoAnswer;
        }
        try std.testing.expect(self.link.state == .connected);
    }
};

test "the session greets the shell's link from its own thread" {
    var bench: Bench = .{};
    try bench.open();
    defer bench.deinit();
    // Nothing answers until the thread runs: the greeting waits on the wire.
    try std.testing.expect(bench.link.pump() == null);
    try std.testing.expect(bench.link.state == .connecting);
    try bench.worker.start();
    try bench.greeted();
    try bench.worker.server().answer();
}

test "a request is answered without the shell's thread serving it" {
    var bench: Bench = .{};
    try bench.open();
    defer bench.deinit();
    try bench.worker.start();
    try bench.greeted();
    const id = try bench.link.send(proto.Now, .now, .{ .core = .cpu0 });
    while (true) {
        if (bench.link.pump()) |arrival| {
            if (arrival == .response and arrival.response.id == id) break;
            continue;
        }
        if (!bench.worker.wait(patience_ns)) return error.NoAnswer;
    }
    // The answer was stamped on the shell's clock as it went on the wire.
    try std.testing.expect(bench.worker.native.answered_ns.load(.acquire) != 0);
}

test "a wait with nothing sent times out" {
    var bench: Bench = .{};
    try bench.open();
    defer bench.deinit();
    try bench.worker.start();
    try bench.greeted();
    while (bench.link.pump() != null) {}
    _ = bench.worker.wait(std.time.ns_per_ms);
    try std.testing.expect(!bench.worker.wait(std.time.ns_per_ms));
}

test "a stopped worker hands the session back, and starts again on it reopened" {
    var bench: Bench = .{};
    try bench.open();
    defer bench.deinit();
    try bench.worker.start();
    try bench.greeted();
    bench.worker.stop();
    try std.testing.expect(bench.worker.thread == null);
    bench.link.close();
    bench.session.deinit();
    try bench.session.open(std.testing.allocator, std.testing.io, image, null);
    bench.worker.rebind();
    bench.link.openNative(&bench.worker.native);
    try bench.worker.start();
    try bench.greeted();
}

test "the camera preview is sampled on the session's thread and relayed" {
    var bench: Bench = .{};
    try bench.open();
    defer bench.deinit();
    // Read before the thread starts: from then on the board is the thread's.
    const direct = bench.session.cameraPreview();
    try bench.worker.start();
    try bench.greeted();
    var tries: u32 = 0;
    const most: u32 = if (direct == null) 20 else 2000;
    const relayed = while (tries < most) : (tries += 1) {
        if (Worker.preview(&bench.worker)) |frame| break frame;
        _ = bench.worker.wait(std.time.ns_per_ms);
    } else null;
    if (direct == null) return try std.testing.expect(relayed == null);
    const frame = relayed orelse return error.NoPreview;
    try std.testing.expectEqual(direct.?.width, frame.width);
    try std.testing.expectEqual(direct.?.height, frame.height);
}
