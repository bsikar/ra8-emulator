//! Tests for how a fork leaves the session's lines: the fork's own
//! intervention belongs to the child, a fork that fails undoes itself, the
//! scheduler position names the line, and the feeder and the graph's
//! persistence follow the line rather than every run slice.
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("fork_fixture.zig");

const record_mod = ra8.session.history_record;
const format_mod = ra8.session.history_format;
const branches_codec = ra8.session.history_branches_codec;
const replay_feeder = ra8.session.history_replay_feeder;
const position_mod = ra8.session.history_position;

const MockHarness = fixture.MockHarness;
const FakeSink = fixture.FakeSink;
const Position = position_mod.Position;

fn at(r: u64, o: u32) Position {
    return .{ .branch = 0, .r = r, .phase = .cpu0, .o = o, .gap = .polled };
}

/// A root line recorded to round 10 with the cursor rewound to round 4.
fn rewound(h: *MockHarness) !void {
    var end = h.graph.get(0).?.recorded_end;
    end.r = 10;
    try h.graph.insertNode(.{ .id = 0, .parent = 0, .fork_at = at(0, 0), .reason = .base, .recorded_end = end });
    h.grid_state.at = at(4, 2);
}

fn failingConsole(_: *anyopaque, _: []const u8) anyerror!void {
    return error.ConsoleGone;
}

test "the fork's own intervention is the child's and replays on the child line" {
    const gpa = std.testing.allocator;
    const h = try MockHarness.init(gpa);
    defer h.deinit();
    try rewound(h);

    try std.testing.expectError(error.ForkNeedsConfirmation, h.session.consoleInput(.cpu0, "typed-at-fork"));
    try h.session.confirmFork();

    // The record and the Branch record both name the child at the fork point.
    const log = h.mock_storage.bytes.items;
    const first = try format_mod.decode(log);
    const branch = try record_mod.decodeBranch(first.frame.payload);
    try std.testing.expectEqual(@as(u32, 1), branch.header.position.branch);
    try std.testing.expectEqual(@as(u32, 1), branch.branch.fork_at.branch);
    try std.testing.expectEqual(@as(u32, 0), branch.branch.parent);
    const second = try format_mod.decode(log[first.consumed..]);
    const interv = try record_mod.decodeIntervention(second.frame.payload);
    try std.testing.expectEqual(@as(u32, 1), interv.header.position.branch);
    try std.testing.expectEqual(@as(u64, 4), interv.header.position.r);

    // A machine restored to the fork on the child line gets it again.
    h.grid_state.at = at(4, 2);
    h.session.stampLine();
    try h.session.loadReplayInterventions(log);
    const feeder = h.session.replay_feeder.?;
    try std.testing.expectEqual(@as(usize, 1), feeder.count());
    const due = feeder.items.items[0].action;
    try std.testing.expectEqualStrings("typed-at-fork", due.console.bytes);
    h.session.releaseReplay();
    try std.testing.expect(h.session.replay_feeder == null);
}

test "an action that fails after the fork leaves the session on its old line" {
    const gpa = std.testing.allocator;
    const h = try MockHarness.init(gpa);
    defer h.deinit();
    var fake = FakeSink.init(gpa);
    defer fake.deinit();
    h.session.attachGraphSink(fake.sink());
    try rewound(h);
    h.session.attachConsole(.{ .context = h, .feedFn = failingConsole });

    try std.testing.expectError(error.ForkNeedsConfirmation, h.session.consoleInput(.cpu0, "doomed"));
    try std.testing.expectError(error.ConsoleGone, h.session.confirmFork());

    // No ghost line: router, graph, recorder segment and branches.bin agree.
    try std.testing.expectEqual(@as(u32, 0), h.router.active_line);
    try std.testing.expectEqual(@as(u32, 0), h.graph.active_branch);
    try std.testing.expect(h.graph.get(1) == null);
    try std.testing.expectEqual(@as(u32, 0), h.recorder.segment.branch);
    try std.testing.expectEqual(@as(u32, 0), h.mock_storage.active_branch);
    try std.testing.expectEqual(@as(u64, 0), h.session.currentPosition().branch);
    var saved = try branches_codec.decode(gpa, fake.last_bytes.items);
    defer saved.deinit();
    try std.testing.expect(saved.get(1) == null);

    // The fork is still pending, and the next live intervention stays live
    // and is recorded on the root, not on a branch that never existed.
    try std.testing.expect(h.session.forkPending() != null);
    h.session.cancelFork();
    h.grid_state.at = at(10, 0);
    h.session.attachConsole(.{ .context = h, .feedFn = @TypeOf(h.*).feedConsole });
    try h.session.consoleInput(.cpu0, "live-again");
    try std.testing.expectEqualStrings("live-again", h.console_fed.?);
    try std.testing.expectEqual(@as(u32, 0), h.router.active_line);
}

test "a fork the action would refuse is refused before the line changes" {
    const gpa = std.testing.allocator;
    const h = try MockHarness.init(gpa);
    defer h.deinit();
    try rewound(h);
    h.session.plugs = null;

    try std.testing.expectError(error.ForkNeedsConfirmation, h.session.plug(.cpu0, .{ .uart = .{ .channel = 1 } }, "term"));
    try std.testing.expectError(error.NoPlugs, h.session.confirmFork());
    try std.testing.expect(h.graph.get(1) == null);
    try std.testing.expectEqual(@as(u32, 0), h.router.active_line);
    try std.testing.expectEqual(@as(usize, 0), h.mock_storage.bytes.items.len);
}

test "the scheduler position names the line after a fork, so comparisons hold on the child" {
    const gpa = std.testing.allocator;
    const h = try MockHarness.init(gpa);
    defer h.deinit();
    try rewound(h);

    try std.testing.expectError(error.ForkNeedsConfirmation, h.session.consoleInput(.cpu0, "x"));
    try h.session.confirmFork();

    try std.testing.expectEqual(@as(u32, 1), h.grid_state.at.branch);
    try std.testing.expectEqual(@as(u32, 1), h.session.currentPosition().branch);
    // A position past the fork, read off the run, orders against one in the
    // shared prefix and against the line's own tip.
    var past = h.grid_state.at;
    past.r = 7;
    try std.testing.expectEqual(std.math.Order.gt, try h.session.comparePositions(past, at(2, 0)));
    try std.testing.expectEqual(std.math.Order.lt, try h.session.comparePositions(h.grid_state.at, past));
    // Restoring a checkpoint rewrites the scheduler state; stampLine puts
    // the line back on it.
    h.grid_state.at.branch = 0;
    h.session.stampLine();
    try std.testing.expectEqual(@as(u32, 1), h.grid_state.at.branch);
}

test "recorded ends move in memory and reach branches.bin on structural changes only" {
    const gpa = std.testing.allocator;
    const h = try MockHarness.init(gpa);
    defer h.deinit();
    var fake = FakeSink.init(gpa);
    defer fake.deinit();
    h.session.attachGraphSink(fake.sink());
    try rewound(h);

    var r: u64 = 11;
    while (r < 60) : (r += 1) h.session.notePosition(at(r, 0));
    try std.testing.expectEqual(@as(u64, 59), h.graph.get(0).?.recorded_end.r);
    try std.testing.expectEqual(@as(usize, 0), fake.called);

    h.grid_state.at = at(4, 2);
    try std.testing.expectError(error.ForkNeedsConfirmation, h.session.consoleInput(.cpu0, "x"));
    try h.session.confirmFork();
    try std.testing.expect(fake.called > 0);
    var saved = try branches_codec.decode(gpa, fake.last_bytes.items);
    defer saved.deinit();
    try std.testing.expectEqual(@as(u64, 59), saved.get(0).?.recorded_end.r);
}

test "a fork drops the parent line's replay feeder" {
    const gpa = std.testing.allocator;
    const h = try MockHarness.init(gpa);
    defer h.deinit();
    try rewound(h);

    // The parent line's future holds a keystroke at round 8.
    var enc = try replay_feeder.encodeAction(gpa, .{ .console = .{ .core = .cpu0, .bytes = "parent-future" } });
    defer replay_feeder.freeEncodedAction(gpa, &enc);
    try h.recorder.recordIntervention(.{ .position = at(8, 0), .seq = 1 }, .{ .what = enc.what, .body = enc.body });
    try h.recorder.commit(1);
    try h.session.loadReplayInterventions(h.mock_storage.bytes.items);
    try std.testing.expectEqual(@as(usize, 1), h.session.replay_feeder.?.count());

    try std.testing.expectError(error.ForkNeedsConfirmation, h.session.consoleInput(.cpu0, "child"));
    try h.session.confirmFork();
    try std.testing.expect(h.session.replay_feeder == null);
}

test "a confirmation after the machine moved is stale and drops the fork" {
    const gpa = std.testing.allocator;
    const h = try MockHarness.init(gpa);
    defer h.deinit();
    try rewound(h);

    try std.testing.expectError(error.ForkNeedsConfirmation, h.session.consoleInput(.cpu0, "asked-at-4"));
    h.grid_state.at = at(5, 0);
    try std.testing.expectError(error.ForkStale, h.session.confirmFork());
    try std.testing.expect(h.session.forkPending() == null);
    try std.testing.expect(h.graph.get(1) == null);
    try std.testing.expectEqual(@as(u32, 0), h.router.active_line);
}
