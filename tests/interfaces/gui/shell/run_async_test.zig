//! Tests for the async path of src/interfaces/gui/shell/run.zig
//! (RA8EMU-1196): a transport-capable link's slices go out as
//! `advance_async`, the queue confirmation leaves the slice out, the
//! transport topic's completion is the answer and its own boundary, and a
//! preempted job hands the pause's halt back.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");

const proto = ra8.rpc.session.rpc;
const shell_run = gui_app.shell.run;
const Run = shell_run.Run;

const Async = struct {
    var event_buf: [128]u8 = undefined;
    var queued_buf: [64]u8 = undefined;

    /// A `finished` transport event that moved `moved_ns` and ended `reason`.
    fn done(moved_ns: u64, reason: proto.StopReason) ![]const u8 {
        return proto.encode(proto.TransportEvent, .{
            .epoch = 1,
            .phase = 0,
            .target_ns = moved_ns,
            .reached_ns = moved_ns,
            .slices = 1,
            .finished = 1,
            .core = .cpu0,
            .from_ns = 0,
            .to_ns = moved_ns,
            .reason = reason,
            .address = 0x40,
        }, &event_buf);
    }

    /// The `advance_async` queue confirmation.
    fn queued() ![]const u8 {
        return proto.encode(proto.AdvanceQueued, .{ .core = .cpu0, .from_ns = 0, .target_ns = 1000 }, &queued_buf);
    }
};

/// An async run with slice 7 out.
fn asyncRun() Run {
    var run: Run = .{};
    run.start(0);
    run.slice_async = true;
    run.slice_id = 7;
    return run;
}

test "async run: the queue confirmation leaves the slice out" {
    var run = asyncRun();
    const seen = run.observe(.{ .response = .{ .id = 7, .result = .{ .ok = try Async.queued() } } }, 0);
    try std.testing.expectEqual(shell_run.Seen.other, seen);
    try std.testing.expectEqual(@as(?u32, 7), run.slice_id);
}

test "async run: the transport completion is the slice and its own boundary" {
    var run = asyncRun();
    const seen = run.observe(.{ .event = .{ .topic = @backingInt(proto.Topic.transport), .payload = try Async.done(2000, .count) } }, 5 * shell_run.share_ns);
    try std.testing.expectEqual(shell_run.Seen.slice, seen);
    try std.testing.expectEqual(@as(?u32, null), run.slice_id);
    try std.testing.expectEqual(@as(u64, 2000), run.board_ns.?);
    try std.testing.expectEqual(@as(u32, 0x40), run.address);
    try std.testing.expect(run.lit);
    // No boundary is due: the stop event behind the completion is not the
    // run's.
    try std.testing.expect(!run.boundary_due);
}

test "async run: a preempted job hands the pause's halt back" {
    var run = asyncRun();
    const seen = run.observe(.{ .event = .{ .topic = @backingInt(proto.Topic.transport), .payload = try Async.done(700, .halt_requested) } }, 0);
    try std.testing.expectEqual(shell_run.Seen.slice, seen);
    try std.testing.expect(!run.lit);
    try std.testing.expectEqual(@as(u32, 0x40), run.halted().?);
}

test "async run: a real stop ends the run without a pause halt" {
    var run = asyncRun();
    const seen = run.observe(.{ .event = .{ .topic = @backingInt(proto.Topic.transport), .payload = try Async.done(700, .breakpoint) } }, 0);
    try std.testing.expectEqual(shell_run.Seen.slice, seen);
    try std.testing.expect(!run.lit);
    try std.testing.expectEqual(@as(?u32, null), run.halted());
}

test "async run: a refused queue confirmation ends the run" {
    var run = asyncRun();
    const seen = run.observe(.{ .response = .{ .id = 7, .result = .{ .err = .bad_args } } }, 0);
    try std.testing.expectEqual(shell_run.Seen.slice, seen);
    try std.testing.expectEqual(@as(?u32, null), run.slice_id);
    try std.testing.expect(run.refused);
    try std.testing.expect(!run.lit);
}
