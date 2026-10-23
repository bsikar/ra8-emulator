//! Graph-level parent branch truncation and deletion planning.
//!
//! Parent deletion preserves all child branches: the parent's own segment is
//! retained through its latest child's fork, discarding only the tail that lies
//! strictly after that fork. A branch with children never becomes a full
//! deletion. The base root branch 0 cannot be deleted when live or when it has
//! no children.
const std = @import("std");
const branch_mod = @import("branch.zig");

pub const Position = branch_mod.Position;
pub const BranchId = branch_mod.BranchId;
pub const BranchGraph = branch_mod.BranchGraph;
pub const Error = branch_mod.Error;

pub const TruncationKind = enum { full_delete, truncate_tail };

pub const TruncationPlan = struct {
    branch_id: BranchId,
    kind: TruncationKind,
    last_child_fork: Position,
    new_recorded_end: Position,
    discard_start: Position,
    discard_end: Position,
};

/// Computes the truncation plan for a branch, enforcing protections and
/// calculating the latest child fork boundary to preserve all child prefixes.
pub fn computeTruncation(graph: *const BranchGraph, id: BranchId) Error!TruncationPlan {
    const node = graph.get(id) orelse return Error.NoSuchBranch;
    if (node.is_live) return Error.BranchActive;
    if (node.pins > 0) return Error.BranchPinned;
    if (node.kept) return Error.BranchKept;

    var latest: ?Position = null;
    var it = graph.nodes.valueIterator();
    while (it.next()) |child| {
        if (child.parent == id and child.id != id) {
            if (latest) |cur_latest| {
                if (branch_mod.scalarOrder(child.fork_at, cur_latest) == .gt) {
                    latest = child.fork_at;
                }
            } else {
                latest = child.fork_at;
            }
        }
    }

    if (latest) |fork_pos| {
        return TruncationPlan{
            .branch_id = id,
            .kind = .truncate_tail,
            .last_child_fork = fork_pos,
            .new_recorded_end = fork_pos,
            .discard_start = fork_pos,
            .discard_end = node.recorded_end,
        };
    }

    if (id == branch_mod.root_branch_id) return Error.RootBranchProtected;

    return TruncationPlan{
        .branch_id = id,
        .kind = .full_delete,
        .last_child_fork = node.fork_at,
        .new_recorded_end = node.fork_at,
        .discard_start = node.fork_at,
        .discard_end = node.recorded_end,
    };
}

/// Applies a computed truncation plan to the graph, updating tail boundaries or removing node.
pub fn applyTruncation(graph: *BranchGraph, plan: TruncationPlan) Error!void {
    switch (plan.kind) {
        .full_delete => {
            _ = graph.nodes.remove(plan.branch_id);
        },
        .truncate_tail => {
            const ptr = graph.nodes.getPtr(plan.branch_id) orelse return Error.NoSuchBranch;
            ptr.recorded_end = plan.new_recorded_end;
            ptr.pruned_tail = true;
        },
    }
}
