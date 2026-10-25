//! Covers src/session/history/seek_engine.zig: the .window base candidate,
//! chosen when the target is inside the window and it is the cheapest.

const std = @import("std");
const ra8 = @import("ra8");
const engine = ra8.session.history_seek_engine;
const branch_mod = ra8.session.history_branch;
const scheduler = ra8.chip.core.scheduler;

const Pos = scheduler.Position;

fn pos(branch: u32, r: u64) Pos {
    return .{ .branch = branch, .r = r, .phase = .cpu0, .o = 0, .gap = .retired };
}

fn ckpt(branch: u32, r: u64, id: u32) engine.Checkpoint {
    return .{
        .position = pos(branch, r),
        .id = id,
        .object = @splat(0x5A),
    };
}

test "forward seek inside window selects window redo base" {
    const facts: engine.Facts = .{
        .current = pos(0, 100),
        .checkpoints = &[_]engine.Checkpoint{ckpt(0, 50, 1)},
        .window = .{
            .start = pos(0, 80),
            .end = pos(0, 150),
            .at = pos(0, 100),
            .line = 0,
            .slots = 70,
        },
    };
    const outcome = engine.plan(.{ .position = .{ .position = pos(0, 120), .branch_named = false } }, facts);
    try std.testing.expectEqualStrings("plan", @tagName(outcome));
    try std.testing.expectEqualStrings("window", @tagName(outcome.plan.base));
    try std.testing.expectEqual(engine.WindowDirection.redo, outcome.plan.base.window.dir);
    try std.testing.expectEqual(@as(u64, 20), outcome.plan.replay_rounds);
    try std.testing.expectEqual(@as(u64, 120), outcome.plan.base.window.position.r);
}

test "backward seek inside window selects window undo base" {
    const facts: engine.Facts = .{
        .current = pos(0, 100),
        .checkpoints = &[_]engine.Checkpoint{ckpt(0, 50, 1)},
        .window = .{
            .start = pos(0, 80),
            .end = pos(0, 150),
            .at = pos(0, 100),
            .line = 0,
            .slots = 70,
        },
    };
    const outcome = engine.plan(.{ .position = .{ .position = pos(0, 85), .branch_named = false } }, facts);
    try std.testing.expectEqualStrings("plan", @tagName(outcome));
    try std.testing.expectEqualStrings("window", @tagName(outcome.plan.base));
    try std.testing.expectEqual(engine.WindowDirection.undo, outcome.plan.base.window.dir);
    try std.testing.expectEqual(@as(u64, 15), outcome.plan.replay_rounds);
    try std.testing.expectEqual(@as(u64, 85), outcome.plan.base.window.position.r);
}

test "backward seek inside window with no checkpoints succeeds via window" {
    const facts: engine.Facts = .{
        .current = pos(0, 100),
        .checkpoints = &.{},
        .window = .{
            .start = pos(0, 80),
            .end = pos(0, 100),
            .at = pos(0, 100),
            .line = 0,
            .slots = 20,
        },
    };
    const outcome = engine.plan(.{ .position = .{ .position = pos(0, 90), .branch_named = false } }, facts);
    try std.testing.expectEqualStrings("plan", @tagName(outcome));
    try std.testing.expectEqualStrings("window", @tagName(outcome.plan.base));
    try std.testing.expectEqual(engine.WindowDirection.undo, outcome.plan.base.window.dir);
    try std.testing.expectEqual(@as(u64, 10), outcome.plan.replay_rounds);
}

test "seek outside window boundaries falls back to checkpoint or pending" {
    const facts: engine.Facts = .{
        .current = pos(0, 100),
        .checkpoints = &[_]engine.Checkpoint{ckpt(0, 50, 1)},
        .window = .{
            .start = pos(0, 80),
            .end = pos(0, 100),
            .at = pos(0, 100),
            .line = 0,
            .slots = 20,
        },
    };
    // Target r=70 is before window start r=80: uses checkpoint
    const outcome = engine.plan(.{ .position = .{ .position = pos(0, 70), .branch_named = false } }, facts);
    try std.testing.expectEqualStrings("plan", @tagName(outcome));
    try std.testing.expectEqualStrings("checkpoint", @tagName(outcome.plan.base));
    try std.testing.expectEqual(@as(u32, 1), outcome.plan.base.checkpoint.id);
    try std.testing.expectEqual(@as(u64, 20), outcome.plan.replay_rounds);

    // Target r=40 is before any checkpoint: pending
    const outcome_pending = engine.plan(.{ .position = .{ .position = pos(0, 40), .branch_named = false } }, facts);
    try std.testing.expectEqualStrings("pending", @tagName(outcome_pending));
    try std.testing.expectEqualStrings("the reverse window's undo base", outcome_pending.pending.what);
}

test "backBase chooses window undo when cursor is covered and not at start" {
    const facts: engine.Facts = .{
        .current = pos(0, 100),
        .checkpoints = &[_]engine.Checkpoint{ckpt(0, 50, 1)},
        .window = .{
            .start = pos(0, 80),
            .end = pos(0, 100),
            .at = pos(0, 100),
            .line = 0,
            .slots = 20,
        },
    };
    const outcome = engine.backBase(pos(0, 100), facts);
    try std.testing.expectEqualStrings("plan", @tagName(outcome));
    try std.testing.expectEqualStrings("window", @tagName(outcome.plan.base));
    try std.testing.expectEqual(engine.WindowDirection.undo, outcome.plan.base.window.dir);

    // When cursor is at window start (r=80), window cannot undo: falls back to checkpoint
    const outcome_at_start = engine.backBase(pos(0, 80), facts);
    try std.testing.expectEqualStrings("plan", @tagName(outcome_at_start));
    try std.testing.expectEqualStrings("checkpoint", @tagName(outcome_at_start.plan.base));
}
