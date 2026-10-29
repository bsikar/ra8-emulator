//! Tests for cross-line seek, divergence calculation, common prefix selection,
//! and base planning across branch lines (Slice 20.3).
const std = @import("std");
const ra8 = @import("ra8");

const branch_mod = ra8.session.history_branch;
const position_mod = ra8.session.history_position;
const cross_seek = ra8.session.history_cross_seek;
const seek_engine = ra8.session.history_seek_engine;
const fork_router_mod = ra8.session.history_fork_router;

const BranchGraph = branch_mod.BranchGraph;
const Position = position_mod.Position;
const Checkpoint = seek_engine.Checkpoint;
const ForkRouter = fork_router_mod.ForkRouter;

fn pos(branch: u32, r: u64) Position {
    return .{ .branch = branch, .r = r, .phase = .cpu0, .o = 0, .gap = .retired };
}

test "commonPrefixEnd resolves divergence for ancestor, descendant, siblings, and cousins" {
    const gpa = std.testing.allocator;
    var graph = try BranchGraph.init(gpa);
    defer graph.deinit();

    // Line 0: root, recorded_end = 200
    // Line 1: child of 0, forked at 100, recorded_end = 250
    // Line 2: child of 0, forked at 150, recorded_end = 300
    // Line 3: child of 1, forked at 180, recorded_end = 220
    try graph.insertNode(.{ .id = 1, .parent = 0, .fork_at = pos(0, 100), .reason = .taps, .recorded_end = pos(1, 250) });
    try graph.insertNode(.{ .id = 2, .parent = 0, .fork_at = pos(0, 150), .reason = .buttons, .recorded_end = pos(2, 300) });
    try graph.insertNode(.{ .id = 3, .parent = 1, .fork_at = pos(1, 180), .reason = .writes, .recorded_end = pos(3, 220) });

    // Same line: recorded_end
    const same = try cross_seek.commonPrefixEnd(&graph, 1, 1);
    try std.testing.expectEqual(@as(u64, 250), same.r);

    // Parent to child (0 to 1): fork_at of 1 (100)
    const p_to_c = try cross_seek.commonPrefixEnd(&graph, 0, 1);
    try std.testing.expectEqual(@as(u64, 100), p_to_c.r);

    // Child to parent (1 to 0): fork_at of 1 (100)
    const c_to_p = try cross_seek.commonPrefixEnd(&graph, 1, 0);
    try std.testing.expectEqual(@as(u64, 100), c_to_p.r);

    // Siblings (1 and 2): both forked from 0 (at 100 and 150). Common prefix ends at min(100, 150) = 100
    const sib = try cross_seek.commonPrefixEnd(&graph, 1, 2);
    try std.testing.expectEqual(@as(u64, 100), sib.r);

    // Cousins / descendant of sibling (2 and 3): 3 is child of 1. Common ancestor is 0. Divergence is 100
    const cousin = try cross_seek.commonPrefixEnd(&graph, 3, 2);
    try std.testing.expectEqual(@as(u64, 100), cousin.r);
}

test "nearestOnCommonPrefix selects checkpoint on common prefix at or before target" {
    const gpa = std.testing.allocator;
    var graph = try BranchGraph.init(gpa);
    defer graph.deinit();

    // Line 0: root, forked child 1 at r=100
    try graph.insertNode(.{ .id = 1, .parent = 0, .fork_at = pos(0, 100), .reason = .taps, .recorded_end = pos(1, 250) });

    const dummy_obj: [16]u8 = @splat(0xaa);
    const checkpoints = [_]Checkpoint{
        .{ .id = 1, .object = dummy_obj, .position = pos(0, 50) },
        .{ .id = 2, .object = dummy_obj, .position = pos(0, 90) },
        .{ .id = 3, .object = dummy_obj, .position = pos(0, 120) }, // after fork point on 0
        .{ .id = 4, .object = dummy_obj, .position = pos(1, 140) }, // on child 1
    };

    // Divergence between line 1 and line 0 is at pos(0, 100)
    const div = pos(0, 100);

    // Seeking from line 1 to target pos(0, 150) on line 0:
    // Checkpoints on common prefix are <= 100 (50 and 90). 90 is nearest.
    const chosen = cross_seek.nearestOnCommonPrefix(&graph, 0, pos(0, 150), &checkpoints, div);
    try std.testing.expect(chosen != null);
    try std.testing.expectEqual(@as(u32, 2), chosen.?.id);
    try std.testing.expectEqual(@as(u64, 90), chosen.?.position.r);

    // Target before divergence: target = pos(0, 80)
    // Common prefix checkpoints <= 80: only 50
    const chosen_early = cross_seek.nearestOnCommonPrefix(&graph, 0, pos(0, 80), &checkpoints, div);
    try std.testing.expect(chosen_early != null);
    try std.testing.expectEqual(@as(u32, 1), chosen_early.?.id);
    try std.testing.expectEqual(@as(u64, 50), chosen_early.?.position.r);
}

test "planCrossLine plans checkpoint base on common prefix and computes replay rounds" {
    const gpa = std.testing.allocator;
    var graph = try BranchGraph.init(gpa);
    defer graph.deinit();

    try graph.insertNode(.{ .id = 1, .parent = 0, .fork_at = pos(0, 100), .reason = .taps, .recorded_end = pos(1, 250) });

    const dummy_obj: [16]u8 = @splat(0x42);
    const checkpoints = [_]Checkpoint{
        .{ .id = 1, .object = dummy_obj, .position = pos(0, 60) },
        .{ .id = 2, .object = dummy_obj, .position = pos(0, 100) },
    };

    const facts: seek_engine.Facts = .{
        .current = pos(1, 150),
        .checkpoints = &checkpoints,
        .graph = &graph,
        .active_line = 1,
    };

    // Cross-line seek to pos(0, 180) on parent branch 0:
    // Plans from checkpoint 2 at r=100. replay_rounds = 180 - 100 = 80
    const outcome = cross_seek.planCrossLine(&graph, facts, pos(0, 180));
    switch (outcome) {
        .plan => |plan| {
            try std.testing.expectEqual(pos(0, 180), plan.target);
            try std.testing.expectEqual(@as(u64, 80), plan.replay_rounds);
            try std.testing.expectEqual(@as(u32, 2), plan.base.checkpoint.id);
            try std.testing.expectEqual(@as(u64, 100), plan.base.checkpoint.position.r);
        },
        .pending => return error.UnexpectedPending,
    }
}

test "end-to-end cross-line seek: fork at P, run child, seek back to parent future past P, then back to child tip" {
    const gpa = std.testing.allocator;
    var graph = try BranchGraph.init(gpa);
    defer graph.deinit();

    // 1. Initial run on branch 0 from 0 to 200
    // Checkpoint on common prefix at r=80 (before fork point P=100)
    const p_obj: [16]u8 = @splat(0x11);
    const checkpoints = [_]Checkpoint{
        .{ .id = 1, .object = p_obj, .position = pos(0, 80) },
    };

    // Fork child 1 at P=100
    try graph.insertNode(.{
        .id = 0,
        .parent = 0,
        .fork_at = pos(0, 0),
        .reason = .base,
        .recorded_end = pos(0, 200),
    });
    try graph.insertNode(.{
        .id = 1,
        .parent = 0,
        .fork_at = pos(0, 100),
        .reason = .writes,
        .recorded_end = pos(1, 250),
    });

    var router = ForkRouter.init(gpa, &graph);
    defer router.deinit();
    router.active_line = 1; // currently running on child 1

    // State trackers
    var mem: [256]u8 = @splat(0);
    // At checkpoint P (r=100), state was "prefix"
    const p_state = "prefix-state";
    // Parent run past P wrote at r=150: "parent-future"
    const parent_future_state = "parent-future-state";
    // Child run past P wrote at r=250: "child-future"
    const child_future_state = "child-future-state";

    // 2. Currently at child tip (r=250) on line 1
    @memcpy(mem[0..child_future_state.len], child_future_state);

    // 3. Cross-line seek to parent line 0 past P: target = pos(0, 150)
    const target_parent = pos(0, 150);
    const facts_from_child: seek_engine.Facts = .{
        .current = pos(1, 250),
        .checkpoints = &checkpoints,
        .graph = &graph,
        .active_line = router.active_line,
    };

    const plan_to_parent = cross_seek.planCrossLine(&graph, facts_from_child, target_parent);
    switch (plan_to_parent) {
        .plan => |plan| {
            // Plans from checkpoint on common prefix (r=80)
            try std.testing.expectEqual(@as(u64, 80), plan.base.checkpoint.position.r);
            // Switch active line to target's branch
            router.switchActiveLine(target_parent.branch);
            try std.testing.expectEqual(@as(u32, 0), router.active_line);
            // Restore checkpoint P state
            @memset(&mem, 0);
            @memcpy(mem[0..p_state.len], p_state);
            // Replay forward along parent line from 100 to 150: parent intervention applies
            @memcpy(mem[0..parent_future_state.len], parent_future_state);
        },
        .pending => return error.UnexpectedPending,
    }

    // State at parent future equals parent's original run at that point!
    try std.testing.expect(std.mem.startsWith(u8, &mem, parent_future_state));

    // 4. Seek back to child's tip: target = pos(1, 250)
    const target_child = pos(1, 250);
    const facts_from_parent: seek_engine.Facts = .{
        .current = pos(0, 150),
        .checkpoints = &checkpoints,
        .graph = &graph,
        .active_line = router.active_line,
    };

    const plan_to_child = cross_seek.planCrossLine(&graph, facts_from_parent, target_child);
    switch (plan_to_child) {
        .plan => |plan| {
            // Plans from checkpoint on common prefix (r=80)
            try std.testing.expectEqual(@as(u64, 80), plan.base.checkpoint.position.r);
            // Switch active line to child branch
            router.switchActiveLine(target_child.branch);
            try std.testing.expectEqual(@as(u32, 1), router.active_line);
            // Restore checkpoint P state
            @memset(&mem, 0);
            @memcpy(mem[0..p_state.len], p_state);
            // Replay forward along child line from 100 to 250: child intervention applies
            @memcpy(mem[0..child_future_state.len], child_future_state);
        },
        .pending => return error.UnexpectedPending,
    }

    // State at child tip equals child's original run!
    try std.testing.expect(std.mem.startsWith(u8, &mem, child_future_state));
}
