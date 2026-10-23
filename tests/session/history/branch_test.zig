//! Covers src/session/history/branch.zig: in-memory branch graph,
//! line ownership, canonical position resolution, and line ordering.
const std = @import("std");
const ra8 = @import("ra8");
const branch_mod = ra8.session.history_branch;
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

test "branch graph initial state has root branch" {
    const gpa = std.testing.allocator;
    var graph = try BranchGraph.init(gpa);
    defer graph.deinit();

    const root = graph.get(0).?;
    try std.testing.expectEqual(@as(u32, 0), root.id);
    try std.testing.expectEqual(@as(u32, 0), root.parent);
    try std.testing.expectEqual(true, root.is_live);
    try std.testing.expectEqual(@as(u32, 1), graph.next_branch_id);
}

test "canonical position mapping on line and fork boundary" {
    const gpa = std.testing.allocator;
    var graph = try BranchGraph.init(gpa);
    defer graph.deinit();

    // Branch 1 forks from 0 at r=50
    const fork1 = makePos(0, 50, 0);
    const b1 = try graph.addBranch(0, fork1, .writes, 1000);
    try std.testing.expectEqual(@as(u32, 1), b1);

    // Branch 2 forks from 1 at r=80
    const fork2 = makePos(1, 80, 0);
    const b2 = try graph.addBranch(b1, fork2, .taps, 2000);
    try std.testing.expectEqual(@as(u32, 2), b2);

    // Points on Line 2:
    // r=30 (< 50) maps to root 0
    const p30 = try graph.canonicalize(b2, makePos(b2, 30, 0));
    try std.testing.expectEqual(@as(u32, 0), p30.branch);
    try std.testing.expectEqual(@as(u64, 30), p30.r);

    // Exact fork position boundary: r=50 belongs to child branch 1
    const p50 = try graph.canonicalize(b2, makePos(b2, 50, 0));
    try std.testing.expectEqual(@as(u32, 1), p50.branch);
    try std.testing.expectEqual(@as(u64, 50), p50.r);

    // r=70 (between 50 and 80) belongs to branch 1
    const p70 = try graph.canonicalize(b2, makePos(b2, 70, 0));
    try std.testing.expectEqual(@as(u32, 1), p70.branch);
    try std.testing.expectEqual(@as(u64, 70), p70.r);

    // Exact fork position boundary: r=80 belongs to child branch 2
    const p80 = try graph.canonicalize(b2, makePos(b2, 80, 0));
    try std.testing.expectEqual(@as(u32, 2), p80.branch);
    try std.testing.expectEqual(@as(u64, 80), p80.r);

    // r=90 belongs to branch 2
    const p90 = try graph.canonicalize(b2, makePos(b2, 90, 0));
    try std.testing.expectEqual(@as(u32, 2), p90.branch);
    try std.testing.expectEqual(@as(u64, 90), p90.r);
}

test "canonicalize refuses points outside line prefix" {
    const gpa = std.testing.allocator;
    var graph = try BranchGraph.init(gpa);
    defer graph.deinit();

    const fork1 = makePos(0, 50, 0);
    const b1 = try graph.addBranch(0, fork1, .writes, 1000);

    // A point claiming branch 0 with r=60 is after fork1, so not on line 1
    const p_invalid = makePos(0, 60, 0);
    try std.testing.expectError(error.OtherLine, graph.canonicalize(b1, p_invalid));

    // A point claiming non-existent or unrelated branch
    const p_unrelated = makePos(99, 30, 0);
    try std.testing.expectError(error.OtherLine, graph.canonicalize(b1, p_unrelated));
}

test "positions compare along line in both directions" {
    const gpa = std.testing.allocator;
    var graph = try BranchGraph.init(gpa);
    defer graph.deinit();

    const fork1 = makePos(0, 50, 0);
    const b1 = try graph.addBranch(0, fork1, .writes, 1000);

    const p_anc = makePos(0, 30, 0);
    const p_desc = makePos(b1, 60, 0);

    // Forward direction: ancestor < descendant
    try std.testing.expectEqual(std.math.Order.lt, try graph.compare(p_anc, p_desc));
    // Reverse direction: descendant > ancestor
    try std.testing.expectEqual(std.math.Order.gt, try graph.compare(p_desc, p_anc));

    // Ancestor point past fork is OtherLine in both directions
    const p_anc_late = makePos(0, 70, 0);
    try std.testing.expectError(error.OtherLine, graph.compare(p_anc_late, p_desc));
    try std.testing.expectError(error.OtherLine, graph.compare(p_desc, p_anc_late));
}

test "fork boundary comparison between parent and child" {
    const gpa = std.testing.allocator;
    var graph = try BranchGraph.init(gpa);
    defer graph.deinit();

    const fork1 = makePos(0, 50, 0);
    const b1 = try graph.addBranch(0, fork1, .writes, 1000);

    // Point on parent strictly before fork compares validly with child
    const p_before = makePos(0, 49, 10);
    const p_at_child = makePos(b1, 50, 0);
    try std.testing.expectEqual(std.math.Order.lt, try graph.compare(p_before, p_at_child));
    try std.testing.expectEqual(std.math.Order.gt, try graph.compare(p_at_child, p_before));

    // Point on parent at exact fork position: belongs to parent's alternate continuation,
    // so it does NOT lie within child's prefix -> OtherLine
    const p_at_parent = makePos(0, 50, 0);
    try std.testing.expectError(error.OtherLine, graph.compare(p_at_parent, p_at_child));
    try std.testing.expectError(error.OtherLine, graph.compare(p_at_child, p_at_parent));
}

test "siblings and cousins produce OtherLine" {
    const gpa = std.testing.allocator;
    var graph = try BranchGraph.init(gpa);
    defer graph.deinit();

    // Sibling branches 1 and 2 both fork from 0
    const b1 = try graph.addBranch(0, makePos(0, 50, 0), .writes, 1000);
    const b2 = try graph.addBranch(0, makePos(0, 60, 0), .taps, 2000);

    // Cousin branches 3 (child of 1) and 4 (child of 2)
    const b3 = try graph.addBranch(b1, makePos(b1, 70, 0), .buttons, 3000);
    const b4 = try graph.addBranch(b2, makePos(b2, 75, 0), .keystrokes, 4000);

    // Siblings comparison -> OtherLine in both directions
    const p_b1 = makePos(b1, 55, 0);
    const p_b2 = makePos(b2, 65, 0);
    try std.testing.expectError(error.OtherLine, graph.compare(p_b1, p_b2));
    try std.testing.expectError(error.OtherLine, graph.compare(p_b2, p_b1));

    // Cousins comparison -> OtherLine in both directions
    const p_b3 = makePos(b3, 72, 0);
    const p_b4 = makePos(b4, 78, 0);
    try std.testing.expectError(error.OtherLine, graph.compare(p_b3, p_b4));
    try std.testing.expectError(error.OtherLine, graph.compare(p_b4, p_b3));
}
