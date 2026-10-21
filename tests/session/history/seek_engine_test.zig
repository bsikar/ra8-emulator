//! Covers src/session/history/seek_engine.zig: the cheapest base a seek
//! replays from, and the target kinds that come back pending naming the
//! index they still need.
const std = @import("std");
const ra8 = @import("ra8");
const engine = ra8.session.history_seek_engine;
const target_mod = ra8.session.history_seek_target;
const scheduler = ra8.chip.core.scheduler;

const Pos = scheduler.Position;

fn pos(branch: u32, r: u64) Pos {
    return .{ .branch = branch, .r = r, .phase = .cpu0, .o = 0, .gap = .retired };
}

fn ckpt(branch: u32, r: u64, id: u32) engine.Checkpoint {
    return .{ .position = pos(branch, r), .id = id, .object = [_]u8{ 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB } };
}

test "a forward seek replays from the live cursor when it is nearest" {
    const facts: engine.Facts = .{
        .current = pos(0, 100),
        .checkpoints = &[_]engine.Checkpoint{ckpt(0, 90, 1)},
    };
    const outcome = engine.plan(.{ .position = .{ .position = pos(0, 105), .branch_named = false } }, facts);
    try std.testing.expectEqualStrings("plan", @tagName(outcome));
    try std.testing.expectEqualStrings("current", @tagName(outcome.plan.base));
    try std.testing.expectEqual(@as(u64, 5), outcome.plan.replay_rounds);
}

test "a forward seek replays from the checkpoint when it is nearest" {
    const facts: engine.Facts = .{
        .current = pos(0, 100),
        .checkpoints = &[_]engine.Checkpoint{ckpt(0, 115, 7)},
    };
    const outcome = engine.plan(.{ .position = .{ .position = pos(0, 120), .branch_named = false } }, facts);
    try std.testing.expectEqualStrings("plan", @tagName(outcome));
    try std.testing.expectEqualStrings("checkpoint", @tagName(outcome.plan.base));
    try std.testing.expectEqual(@as(u32, 7), outcome.plan.base.checkpoint.id);
    try std.testing.expectEqual(@as(u64, 5), outcome.plan.replay_rounds);
}

test "a forward tie goes to the live cursor" {
    const facts: engine.Facts = .{
        .current = pos(0, 100),
        .checkpoints = &[_]engine.Checkpoint{ ckpt(0, 90, 1), ckpt(0, 60, 2) },
    };
    const outcome = engine.plan(.{ .position = .{ .position = pos(0, 100), .branch_named = false } }, facts);
    try std.testing.expectEqualStrings("plan", @tagName(outcome));
    try std.testing.expectEqualStrings("current", @tagName(outcome.plan.base));
    try std.testing.expectEqual(@as(u64, 0), outcome.plan.replay_rounds);
}

test "a forward seek with no checkpoint starts from the cursor" {
    const facts: engine.Facts = .{ .current = pos(0, 40), .checkpoints = &[_]engine.Checkpoint{} };
    const outcome = engine.plan(.{ .position = .{ .position = pos(0, 50), .branch_named = false } }, facts);
    try std.testing.expectEqualStrings("plan", @tagName(outcome));
    try std.testing.expectEqualStrings("current", @tagName(outcome.plan.base));
    try std.testing.expectEqual(@as(u64, 10), outcome.plan.replay_rounds);
}

test "a backward seek replays from the nearest checkpoint at or before it" {
    const facts: engine.Facts = .{
        .current = pos(0, 100),
        .checkpoints = &[_]engine.Checkpoint{ ckpt(0, 64, 3), ckpt(0, 20, 2) },
    };
    const outcome = engine.plan(.{ .position = .{ .position = pos(0, 70), .branch_named = false } }, facts);
    try std.testing.expectEqualStrings("plan", @tagName(outcome));
    try std.testing.expectEqualStrings("checkpoint", @tagName(outcome.plan.base));
    try std.testing.expectEqual(@as(u32, 3), outcome.plan.base.checkpoint.id);
    try std.testing.expectEqual(@as(u64, 6), outcome.plan.replay_rounds);
}

test "a backward seek with no checkpoint at or before it is pending, naming the window" {
    const facts: engine.Facts = .{
        .current = pos(0, 100),
        .checkpoints = &[_]engine.Checkpoint{ckpt(0, 120, 4)},
    };
    const outcome = engine.plan(.{ .position = .{ .position = pos(0, 70), .branch_named = false } }, facts);
    try std.testing.expectEqualStrings("pending", @tagName(outcome));
    try std.testing.expectEqualStrings("the reverse window's undo base", outcome.pending.what);
}

test "another line's seek is pending, never planned across branches" {
    const facts: engine.Facts = .{
        .current = pos(0, 100),
        .checkpoints = &[_]engine.Checkpoint{ckpt(1, 90, 5)},
    };
    const outcome = engine.plan(.{ .position = .{ .position = pos(1, 90), .branch_named = true } }, facts);
    try std.testing.expectEqualStrings("pending", @tagName(outcome));
    try std.testing.expectEqualStrings("another line's seek", outcome.pending.what);
}

test "target kinds whose indexes have not landed come back pending" {
    const facts: engine.Facts = .{ .current = pos(0, 100), .checkpoints = &[_]engine.Checkpoint{} };
    const cases = [_]struct { target: target_mod.Target, want: []const u8 }{
        .{ .target = .{ .time = .{ .relative = false, .ns = 1_500 } }, .want = "the virtual-time index" },
        .{ .target = .{ .percent = .{ .relative = false, .basis_points = 2_500 } }, .want = "the virtual-time index" },
        .{ .target = .{ .frame = .{ .index = 4 } }, .want = "the frame index" },
        .{ .target = .{ .frame = .prev }, .want = "the frame index" },
        .{ .target = .{ .iteration = .{ .n = 3 } }, .want = "the round-boundary index" },
        .{ .target = .{ .bookmark = .{ .name = "boot" } }, .want = "bookmark storage" },
        .{ .target = .{ .point = .{ .address = 0x0800_0100, .nth = 2 } }, .want = "the arrival index" },
    };
    for (cases) |case| {
        const outcome = engine.plan(case.target, facts);
        try std.testing.expectEqualStrings("pending", @tagName(outcome));
        try std.testing.expectEqualStrings(case.want, outcome.pending.what);
    }
}
