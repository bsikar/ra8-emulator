//! Cross-line seek resolution and common-prefix base planning (Slice 20.3).
//!
//! When seeking to a target position on another branch line, this module resolves
//! the divergence boundary (common prefix) between the current line and the target line,
//! selects the nearest checkpoint on that common prefix at or before the target,
//! and plans the replay along the target line.
const std = @import("std");
const branch_mod = @import("branch.zig");
const position_mod = @import("position.zig");
const seek_engine = @import("seek_engine.zig");

pub const Position = position_mod.Position;
pub const BranchId = branch_mod.BranchId;
pub const BranchGraph = branch_mod.BranchGraph;
pub const Checkpoint = seek_engine.Checkpoint;
pub const Outcome = seek_engine.Outcome;

/// Resolves the position where two branch lines diverge.
pub fn commonPrefixEnd(
    graph: *const BranchGraph,
    from_line: BranchId,
    to_line: BranchId,
) !Position {
    if (from_line == to_line) {
        const node = graph.get(to_line) orelse return error.NoSuchBranch;
        return node.recorded_end;
    }
    if (graph.isAncestorOrSelf(to_line, from_line)) {
        const child_id = graph.childLeadingTo(to_line, from_line) orelse return error.NoSuchBranch;
        const child_node = graph.get(child_id) orelse return error.NoSuchBranch;
        return child_node.fork_at;
    }
    if (graph.isAncestorOrSelf(from_line, to_line)) {
        const child_id = graph.childLeadingTo(from_line, to_line) orelse return error.NoSuchBranch;
        const child_node = graph.get(child_id) orelse return error.NoSuchBranch;
        return child_node.fork_at;
    }
    const lca = findLca(graph, from_line, to_line) orelse return error.OtherLine;
    const child_from = graph.childLeadingTo(lca, from_line) orelse return error.NoSuchBranch;
    const child_to = graph.childLeadingTo(lca, to_line) orelse return error.NoSuchBranch;
    const n_from = graph.get(child_from) orelse return error.NoSuchBranch;
    const n_to = graph.get(child_to) orelse return error.NoSuchBranch;
    if (branch_mod.scalarOrder(n_from.fork_at, n_to.fork_at) == .lt) {
        return n_from.fork_at;
    }
    return n_to.fork_at;
}

fn findLca(graph: *const BranchGraph, a: BranchId, b: BranchId) ?BranchId {
    var cur: ?BranchId = a;
    while (cur) |id| {
        if (graph.isAncestorOrSelf(id, b)) return id;
        const node = graph.get(id) orelse break;
        if (node.parent == id) break;
        cur = node.parent;
    }
    return null;
}

/// Finds the nearest checkpoint on the common prefix at or before target.
pub fn nearestOnCommonPrefix(
    graph: *const BranchGraph,
    target_line: BranchId,
    target: Position,
    checkpoints: []const Checkpoint,
    div_pos: Position,
) ?Checkpoint {
    var best: ?Checkpoint = null;
    var best_at: Position = .{};
    for (checkpoints) |c| {
        const c_canon = graph.canonicalize(target_line, c.position) catch continue;
        if (branch_mod.scalarOrder(c_canon, div_pos) == .gt) continue;
        if (branch_mod.scalarOrder(c_canon, target) == .gt) continue;
        if (best == null or branch_mod.scalarOrder(c_canon, best_at) == .gt) {
            best = c;
            best_at = c_canon;
        }
    }
    return best;
}

/// Plans a cross-line seek from facts.active_line to target on target.branch.
pub fn planCrossLine(
    graph: *const BranchGraph,
    facts: seek_engine.Facts,
    target: Position,
) Outcome {
    const target_line = target.branch;
    _ = graph.canonicalize(target_line, target) catch
        return .{ .pending = .{ .what = "another line's seek" } };

    const div_pos = commonPrefixEnd(graph, facts.active_line, target_line) catch
        return .{ .pending = .{ .what = "another line's seek" } };

    const best = nearestOnCommonPrefix(graph, target_line, target, facts.checkpoints, div_pos) orelse
        return .{ .pending = .{ .what = "the reverse window's undo base" } };

    return .{ .plan = .{
        .base = .{ .checkpoint = .{
            .id = best.id,
            .object = best.object,
            .position = best.position,
        } },
        .replay_rounds = target.r -| best.position.r,
    } };
}
