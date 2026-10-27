//! Tests for seek_engine resolution of navigation targets (Slice 22.4).
//! Verifies planning for frame, iteration, point, and bookmark targets using NavIndex.
const std = @import("std");
const ra8 = @import("ra8");
const engine = ra8.session.history_seek_engine;
const nav_index = ra8.session.history_nav_index;
const target_mod = ra8.session.history_seek_target;
const scheduler = ra8.chip.core.scheduler;

const Pos = scheduler.Position;

fn pos(branch: u32, r: u64) Pos {
    return .{ .branch = branch, .r = r, .phase = .cpu0, .o = 0, .gap = .retired };
}

fn ckpt(branch: u32, r: u64, id: u32) engine.Checkpoint {
    return .{
        .position = pos(branch, r),
        .id = id,
        .object = [_]u8{ 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB },
    };
}

test "seek engine plans frame target when nav index is provided" {
    const allocator = std.testing.allocator;
    var nav = nav_index.NavIndex.init(allocator);
    defer nav.deinit();

    _ = try nav.addFrame(pos(0, 50), 50_000);
    _ = try nav.addFrame(pos(0, 100), 100_000);
    _ = try nav.addFrame(pos(0, 150), 150_000);

    const facts: engine.Facts = .{
        .current = pos(0, 20),
        .checkpoints = &[_]engine.Checkpoint{ ckpt(0, 40, 1), ckpt(0, 80, 2) },
        .nav = &nav,
    };

    // frame 1 -> position at round 100
    const target = try target_mod.parse("frame 1");
    const outcome = engine.plan(target, facts);
    try std.testing.expectEqualStrings("plan", @tagName(outcome));
    try std.testing.expectEqual(pos(0, 100), outcome.plan.target);
    try std.testing.expectEqualStrings("checkpoint", @tagName(outcome.plan.base));
    try std.testing.expectEqual(@as(u32, 2), outcome.plan.base.checkpoint.id);
    try std.testing.expectEqual(@as(u64, 20), outcome.plan.replay_rounds);
}

test "seek engine plans iteration target when nav index is provided" {
    const allocator = std.testing.allocator;
    var nav = nav_index.NavIndex.init(allocator);
    defer nav.deinit();

    _ = try nav.addIteration(pos(0, 30));
    _ = try nav.addIteration(pos(0, 60));

    const facts: engine.Facts = .{
        .current = pos(0, 10),
        .checkpoints = &[_]engine.Checkpoint{ckpt(0, 20, 5)},
        .nav = &nav,
    };

    const target = try target_mod.parse("iter 2");
    const outcome = engine.plan(target, facts);
    try std.testing.expectEqualStrings("plan", @tagName(outcome));
    try std.testing.expectEqual(pos(0, 60), outcome.plan.target);
    try std.testing.expectEqualStrings("checkpoint", @tagName(outcome.plan.base));
    try std.testing.expectEqual(@as(u32, 5), outcome.plan.base.checkpoint.id);
    try std.testing.expectEqual(@as(u64, 40), outcome.plan.replay_rounds);
}

test "seek engine plans point arrival and bookmark targets" {
    const allocator = std.testing.allocator;
    var nav = nav_index.NavIndex.init(allocator);
    defer nav.deinit();

    _ = try nav.addMarkerArrival("m1", 0x0800_1000, pos(0, 25));
    _ = try nav.addMarkerArrival("m1", 0x0800_1000, pos(0, 75));
    try nav.setBookmark("loop_top", pos(0, 75));

    const facts: engine.Facts = .{
        .current = pos(0, 10),
        .checkpoints = &[_]engine.Checkpoint{},
        .nav = &nav,
    };

    // Point arrival: arrival 2 0x08001000 -> round 75
    const pt_target = try target_mod.parse("arrival 2 0x08001000");
    const pt_outcome = engine.plan(pt_target, facts);
    try std.testing.expectEqualStrings("plan", @tagName(pt_outcome));
    try std.testing.expectEqual(pos(0, 75), pt_outcome.plan.target);
    try std.testing.expectEqualStrings("current", @tagName(pt_outcome.plan.base));
    try std.testing.expectEqual(@as(u64, 65), pt_outcome.plan.replay_rounds);

    // Bookmark: bm loop_top -> round 75
    const bm_target = try target_mod.parse("bm loop_top");
    const bm_outcome = engine.plan(bm_target, facts);
    try std.testing.expectEqualStrings("plan", @tagName(bm_outcome));
    try std.testing.expectEqual(pos(0, 75), bm_outcome.plan.target);
}
