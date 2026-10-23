//! Covers src/session/history/branch_prune.zig: parent truncation preserving
//! all child prefixes, protection enforcement, and leaf deletion.
const std = @import("std");
const ra8 = @import("ra8");
const branch_mod = ra8.session.history_branch;
const prune = ra8.session.history_branch_prune;
const scheduler = ra8.chip.core.scheduler;

const Position = scheduler.Position;
const BranchGraph = branch_mod.BranchGraph;

fn makePos(branch: u32, r: u64, o: u32) Position {
    return .{
        .branch = branch,
        .r = r,
        .phase = .cpu0,
        .o = o,
        .gap = .retired,
    };
}

test "parent truncation preserves every child up to latest child fork" {
    const gpa = std.testing.allocator;
    var graph = try BranchGraph.init(gpa);
    defer graph.deinit();

    // Parent P (branch 1) forked from 0 at r=20
    const b_p = try graph.addBranch(0, makePos(0, 20, 0), .writes, 500);
    var p_node = graph.get(b_p).?;
    p_node.recorded_end = makePos(b_p, 100, 0);
    try graph.insertNode(p_node);

    // Child C1 forks at r=50; Child C2 forks later at r=70
    const b_c1 = try graph.addBranch(b_p, makePos(b_p, 50, 0), .taps, 1000);
    const b_c2 = try graph.addBranch(b_p, makePos(b_p, 70, 0), .buttons, 2000);

    // Compute truncation on parent P
    const plan = try prune.computeTruncation(&graph, b_p);
    try std.testing.expectEqual(prune.TruncationKind.truncate_tail, plan.kind);
    // Must retain through the LATEST child fork (r=70), not earliest (r=50)
    try std.testing.expectEqual(@as(u64, 70), plan.last_child_fork.r);
    try std.testing.expectEqual(@as(u64, 70), plan.new_recorded_end.r);
    try std.testing.expectEqual(@as(u64, 70), plan.discard_start.r);
    try std.testing.expectEqual(@as(u64, 100), plan.discard_end.r);

    // Apply truncation
    try prune.applyTruncation(&graph, plan);
    const updated_p = graph.get(b_p).?;
    try std.testing.expectEqual(@as(u64, 70), updated_p.recorded_end.r);
    try std.testing.expectEqual(true, updated_p.pruned_tail);

    // Both children lines still canonicalize and compare correctly!
    // On C1's line: r=40 belongs to P, r=50 belongs to C1
    const c1_p40 = try graph.canonicalize(b_c1, makePos(b_c1, 40, 0));
    try std.testing.expectEqual(b_p, c1_p40.branch);

    // On C2's line: r=60 is between 50 and 70; it MUST still belong to P and be preserved!
    const c2_p60 = try graph.canonicalize(b_c2, makePos(b_c2, 60, 0));
    try std.testing.expectEqual(b_p, c2_p60.branch);
    try std.testing.expectEqual(@as(u64, 60), c2_p60.r);

    // C2's line compares r=60 and r=75 validly
    const c2_p75 = makePos(b_c2, 75, 0);
    try std.testing.expectEqual(std.math.Order.lt, try graph.compareOnLine(b_c2, makePos(b_c2, 60, 0), c2_p75));
}

test "deleting a child does not touch the parent" {
    const gpa = std.testing.allocator;
    var graph = try BranchGraph.init(gpa);
    defer graph.deinit();

    const b_p = try graph.addBranch(0, makePos(0, 20, 0), .writes, 500);
    var p_node = graph.get(b_p).?;
    p_node.recorded_end = makePos(b_p, 100, 0);
    try graph.insertNode(p_node);

    const b_c1 = try graph.addBranch(b_p, makePos(b_p, 50, 0), .taps, 1000);

    // Child C1 has no children: deleting it is full_delete
    const c1_plan = try prune.computeTruncation(&graph, b_c1);
    try std.testing.expectEqual(prune.TruncationKind.full_delete, c1_plan.kind);

    try prune.applyTruncation(&graph, c1_plan);
    try std.testing.expect(graph.get(b_c1) == null);

    // Parent P is completely untouched
    const p_after = graph.get(b_p).?;
    try std.testing.expectEqual(@as(u64, 100), p_after.recorded_end.r);
    try std.testing.expectEqual(false, p_after.pruned_tail);
}

test "branch with children never becomes full_delete" {
    const gpa = std.testing.allocator;
    var graph = try BranchGraph.init(gpa);
    defer graph.deinit();

    const b_p = try graph.addBranch(0, makePos(0, 20, 0), .writes, 500);
    _ = try graph.addBranch(b_p, makePos(b_p, 20, 0), .taps, 1000);

    const plan = try prune.computeTruncation(&graph, b_p);
    try std.testing.expect(plan.kind != .full_delete);
    try std.testing.expectEqual(prune.TruncationKind.truncate_tail, plan.kind);
}

test "truncation refuses live base branch 0 and protected branches" {
    const gpa = std.testing.allocator;
    var graph = try BranchGraph.init(gpa);
    defer graph.deinit();

    // Root branch 0 is live by default -> error.BranchActive
    try std.testing.expectError(error.BranchActive, prune.computeTruncation(&graph, 0));

    // Base branch 0 without children even if not live -> error.RootBranchProtected
    var root_node = graph.get(0).?;
    root_node.is_live = false;
    try graph.insertNode(root_node);
    try std.testing.expectError(error.RootBranchProtected, prune.computeTruncation(&graph, 0));

    // Protections on child branch
    const b1 = try graph.addBranch(0, makePos(0, 20, 0), .writes, 500);
    var node1 = graph.get(b1).?;
    node1.pins = 1;
    try graph.insertNode(node1);
    try std.testing.expectError(error.BranchPinned, prune.computeTruncation(&graph, b1));

    node1.pins = 0;
    node1.kept = true;
    try graph.insertNode(node1);
    try std.testing.expectError(error.BranchKept, prune.computeTruncation(&graph, b1));

    node1.kept = false;
    node1.is_live = true;
    try graph.insertNode(node1);
    try std.testing.expectError(error.BranchActive, prune.computeTruncation(&graph, b1));
}
