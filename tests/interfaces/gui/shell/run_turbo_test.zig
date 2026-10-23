//! Tests for the turbo advance path of src/interfaces/gui/shell/run.zig (slice 19).
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const session_link = gui_app.session_link;

const proto = ra8.rpc.session.rpc;
const shell_run = gui_app.shell.run;
const Run = shell_run.Run;

var queued_buf: [64]u8 = undefined;
var turbo_buf: [64]u8 = undefined;

fn queued(target_ns: u64) ![]const u8 {
    return proto.encode(proto.AdvanceQueued, .{ .core = .cpu0, .from_ns = 0, .target_ns = target_ns }, &queued_buf);
}

fn turbo_event(to_ns: u64) ![]const u8 {
    // phase 3 is the transport's advancing phase in its own order.
    return proto.encode(proto.TransportEvent, .{ .epoch = 1, .phase = 3, .target_ns = to_ns, .reached_ns = to_ns, .slices = 1, .finished = 1, .core = .cpu0, .from_ns = 0, .to_ns = to_ns, .reason = .count, .address = 0x0200_0000 }, &turbo_buf);
}

fn turbo_progress(reached_ns: u64) ![]const u8 {
    // A mid-run progress event: the aim is still the queued target.
    return proto.encode(proto.TransportEvent, .{ .epoch = 1, .phase = 3, .target_ns = 1_000_000_000, .reached_ns = reached_ns, .slices = 1, .finished = 0, .core = .cpu0, .from_ns = 0, .to_ns = reached_ns, .reason = .count, .address = 0x0200_0000 }, &turbo_buf);
}

test "turbo: a lit run refuses one" {
    var run: Run = .{};
    run.start(0x0200_0000);
    var link = session_link.Link{};
    try std.testing.expectError(error.NotReady, run.turbo(&link, 1_000_000));
}

test "turbo: a link without a transport refuses one" {
    var run: Run = .{};
    var link = session_link.Link{};
    try std.testing.expectError(error.NotReady, run.turbo(&link, 1_000_000));
}

test "turbo: the queue confirmation arms the job" {
    var run: Run = .{};
    run.turbo_id = 7;
    const seen = run.observe(.{ .response = .{ .id = 7, .result = .{ .ok = try queued(1_000_000) } } }, 0);
    try std.testing.expectEqual(shell_run.Seen.other, seen);
    try std.testing.expect(run.turbo_out);
    try std.testing.expect(run.turbo_id == null);
}

test "turbo: the completion lands and wants the clock read again" {
    var run: Run = .{};
    run.turbo_out = true;
    const seen = run.observe(.{ .event = .{ .topic = @backingInt(proto.Topic.transport), .payload = try turbo_event(2_000_000) } }, 0);
    try std.testing.expectEqual(shell_run.Seen.slice, seen);
    try std.testing.expect(!run.turbo_out);
    try std.testing.expectEqual(@as(?u64, 2_000_000), run.board_ns);
    try std.testing.expect(run.takeTurboArrival());
    try std.testing.expect(!run.takeTurboArrival());
}

test "turbo: the queue's refusal is marked for the status bar" {
    var run: Run = .{};
    run.turbo_id = 7;
    _ = run.observe(.{ .response = .{ .id = 7, .result = .{ .err = .not_ready } } }, 0);
    try std.testing.expect(run.turbo_refused);
    try std.testing.expect(run.turbo_id == null);
}

test "turbo: progress events estimate the remaining time from the rate so far" {
    var run: Run = .{};
    run.turbo_id = 7;
    _ = run.observe(.{ .response = .{ .id = 7, .result = .{ .ok = try queued(1_000_000_000) } } }, 0);
    try std.testing.expectEqual(@as(u64, 1_000_000_000), run.turbo_target_ns);
    try std.testing.expectEqual(@as(u64, 0), run.turbo_from_ns);
    const seen = run.observe(.{ .event = .{ .topic = @backingInt(proto.Topic.transport), .payload = try turbo_progress(500_000_000) } }, 1_000_000);
    try std.testing.expectEqual(shell_run.Seen.other, seen);
    // Half the distance in 1ms of wall time means 1ms left to cover the rest.
    try std.testing.expectEqual(@as(?u64, 1_000_000), run.turbo_eta);
    // The completion lands and clears the estimate with the bookkeeping.
    const done = run.observe(.{ .event = .{ .topic = @backingInt(proto.Topic.transport), .payload = try turbo_event(1_000_000_000) } }, 2_000_000);
    try std.testing.expectEqual(shell_run.Seen.slice, done);
    try std.testing.expect(run.turbo_eta == null);
    try std.testing.expectEqual(@as(u64, 0), run.turbo_target_ns);
    try std.testing.expectEqual(@as(u64, 0), run.turbo_from_ns);
}
