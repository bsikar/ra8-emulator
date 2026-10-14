//! Tests for src/interfaces/gui/shared_wire.zig: the loopback's two ends
//! through the shared wire, the events each send sets, the shell's end
//! refusing a full pipe, and the session's end waiting for room.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const Manual = @import("manual_clock.zig").Manual;

const rpc = ra8.rpc.session.server.rpc_lib;
const Wire = gui_app.shared_wire.Wire;

const Bench = struct {
    to_session: [8]u8 = undefined,
    to_shell: [8]u8 = undefined,
    loop: rpc.Loopback = undefined,
    clock: Manual = .{ .now_ns = 700 },
    wire: Wire = undefined,

    /// In place: the wire points at the loopback and the clock.
    fn open(self: *Bench) void {
        self.loop = rpc.Loopback.init(&self.to_session, &self.to_shell);
        self.wire = .{ .io = std.testing.io, .loop = &self.loop, .clock = self.clock.clock() };
    }
};

test "what the shell sends reaches the session's end, and says so" {
    var bench: Bench = .{};
    bench.open();
    try std.testing.expectEqual(@as(usize, 0), bench.wire.session().poll());
    try std.testing.expect(!bench.wire.asked.isSet());
    try bench.wire.shell().send("ask");
    try std.testing.expect(bench.wire.asked.isSet());
    try std.testing.expectEqual(@as(usize, 3), bench.wire.session().poll());
    var got: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try bench.wire.session().receive(&got));
    try std.testing.expectEqualStrings("ask", got[0..3]);
}

test "what the session sends reaches the shell's end, stamped on the shell's clock" {
    var bench: Bench = .{};
    bench.open();
    try std.testing.expect(!bench.wire.answered.isSet());
    try bench.wire.session().send("done");
    try std.testing.expect(bench.wire.answered.isSet());
    try std.testing.expectEqual(@as(u64, 700), bench.wire.answered_ns.load(.acquire));
    try std.testing.expectEqual(@as(usize, 4), bench.wire.shell().poll());
    var got: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try bench.wire.shell().receive(&got));
    try std.testing.expectEqualStrings("done", got[0..4]);
    // Taking bytes is what makes room for a session waiting to send.
    try std.testing.expect(bench.wire.room.isSet());
}

test "the shell's end never waits: a full pipe is refused whole" {
    var bench: Bench = .{};
    bench.open();
    try bench.wire.shell().send("12345678");
    try std.testing.expectError(error.LinkFull, bench.wire.shell().send("9"));
    try std.testing.expectEqual(@as(usize, 8), bench.wire.session().poll());
}

fn sendLate(wire: *Wire, sent: *std.atomic.Value(bool)) void {
    wire.session().send("late") catch return;
    sent.store(true, .release);
}

test "the session's end waits for room and sends once the shell takes" {
    var bench: Bench = .{};
    bench.open();
    try bench.wire.session().send("12345678");
    var sent: std.atomic.Value(bool) = .init(false);
    const thread = try std.Thread.spawn(.{}, sendLate, .{ &bench.wire, &sent });
    var got: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 8), try bench.wire.shell().receive(&got));
    thread.join();
    try std.testing.expect(sent.load(.acquire));
    try std.testing.expectEqual(@as(usize, 4), try bench.wire.shell().receive(&got));
    try std.testing.expectEqualStrings("late", got[0..4]);
}

test "a closed wire reads as down to a session waiting on it" {
    var bench: Bench = .{};
    bench.open();
    try bench.wire.session().send("12345678");
    bench.wire.close();
    try std.testing.expectError(error.LinkDown, bench.wire.session().send("more"));
    try std.testing.expect(bench.wire.asked.isSet());
}
