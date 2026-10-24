//! Branch lifecycle operations: listing, switching and removing branches (Slice 20.4).
//!
//! Provides pure query and planning over the branch graph, plus Session-level
//! switch and removal workflows. Changes persist branches.bin through the session's
//! graph sink. Parent removal preserves all child lines by truncating only the
//! segment strictly following the latest child fork.
const std = @import("std");
const branch_mod = @import("branch.zig");
const branch_prune = @import("branch_prune.zig");
const branches_codec = @import("branches_codec.zig");
const cross_seek = @import("cross_seek.zig");
const seek_engine = @import("seek_engine.zig");
const api = @import("../api.zig");
const transport_mod = @import("../transport/transport.zig");

pub const Position = branch_mod.Position;
pub const ForkReason = branch_mod.ForkReason;
pub const BranchId = branch_mod.BranchId;
pub const BranchGraph = branch_mod.BranchGraph;
pub const TruncationKind = branch_prune.TruncationKind;
pub const TruncationPlan = branch_prune.TruncationPlan;
pub const Session = api.Session;
pub const Transport = transport_mod.Transport;

pub const Error = error{
    NoSuchBranch,
    BranchActive,
    BranchPinned,
    BranchKept,
    RootBranchProtected,
    ConfirmRequired,
    NotHalted,
    NoHistory,
    CannotPlan,
    OutOfMemory,
};

pub const BranchInfo = struct {
    id: BranchId,
    parent: BranchId,
    fork_at: Position,
    reason: ForkReason,
    recorded_end: Position,
    is_live: bool,
    is_kept: bool,
    is_pinned: bool,
    child_count: u32,
};

fn countChildren(graph: *const BranchGraph, id: BranchId) u32 {
    var count: u32 = 0;
    var it = graph.nodes.valueIterator();
    while (it.next()) |node| {
        if (node.parent == id and node.id != id) count += 1;
    }
    return count;
}

fn compareBranchInfo(_: void, a: BranchInfo, b: BranchInfo) bool {
    return a.id < b.id;
}

/// Returns a sorted list of all branches in the graph.
pub fn list(allocator: std.mem.Allocator, graph: *const BranchGraph, active_line: BranchId) ![]BranchInfo {
    var items: std.ArrayList(BranchInfo) = .empty;
    defer items.deinit(allocator);

    var it = graph.nodes.valueIterator();
    while (it.next()) |node| {
        try items.append(allocator, .{
            .id = node.id,
            .parent = node.parent,
            .fork_at = node.fork_at,
            .reason = node.reason,
            .recorded_end = node.recorded_end,
            .is_live = (node.id == active_line),
            .is_kept = node.kept,
            .is_pinned = (node.pins > 0),
            .child_count = countChildren(graph, node.id),
        });
    }

    const slice = try items.toOwnedSlice(allocator);
    std.mem.sort(BranchInfo, slice, {}, compareBranchInfo);
    return slice;
}

/// Persists the branch graph through the session's graph sink if attached.
pub fn persistGraph(session: *Session) !void {
    const sink = session.graph_sink orelse return;
    const router = session.fork_router orelse return;
    const graph = router.graph orelse return;
    const encoded = try branches_codec.encodeAlloc(graph, router.allocator);
    defer router.allocator.free(encoded);
    try sink.writeFn(sink.context, encoded);
}

/// Switches active execution line to target branch (machine must be halted).
pub fn switchBranch(session: *Session, transport: ?*Transport, target_id: BranchId) !void {
    const router = session.fork_router orelse return Error.NoHistory;
    const graph = router.graph orelse return Error.NoHistory;
    const target_node = graph.get(target_id) orelse return Error.NoSuchBranch;

    if (transport) |t| {
        if (t.busy() != null) return Error.NotHalted;
    }

    if (router.active_line == target_id) return;

    if (transport) |t| {
        if (t.history) |bridge| {
            var facts = bridge.facts(bridge.context) catch return Error.NoHistory;
            facts.graph = graph;
            facts.active_line = router.active_line;
            const outcome = cross_seek.planCrossLine(graph, facts, target_node.recorded_end);
            switch (outcome) {
                .plan => |plan| {
                    try bridge.restore(bridge.context, &plan.base.checkpoint.object);
                    router.switchActiveLine(target_id);
                },
                .pending => return Error.CannotPlan,
            }
        } else {
            router.switchActiveLine(target_id);
        }
    } else {
        router.switchActiveLine(target_id);
    }

    try persistGraph(session);
}

/// Pure branch deletion planning and application over a BranchGraph.
pub fn removeBranchPure(graph: *BranchGraph, active_line: ?BranchId, target_id: BranchId, confirm: bool) !TruncationPlan {
    if (!confirm) return Error.ConfirmRequired;
    if (active_line) |act| {
        if (target_id == act) return Error.BranchActive;
    }
    const plan = branch_prune.computeTruncation(graph, target_id) catch |err| switch (err) {
        branch_mod.Error.NoSuchBranch => return Error.NoSuchBranch,
        branch_mod.Error.BranchActive => return Error.BranchActive,
        branch_mod.Error.BranchPinned => return Error.BranchPinned,
        branch_mod.Error.BranchKept => return Error.BranchKept,
        branch_mod.Error.RootBranchProtected => return Error.RootBranchProtected,
        else => return Error.CannotPlan,
    };
    try branch_prune.applyTruncation(graph, plan);
    return plan;
}

/// Removes a branch with explicit confirmation, preserving child trunk segments.
pub fn removeBranch(session: *Session, target_id: BranchId, confirm: bool) !TruncationPlan {
    const router = session.fork_router orelse return Error.NoHistory;
    const graph = router.graph orelse return Error.NoHistory;
    const plan = try removeBranchPure(graph, router.active_line, target_id, confirm);
    try persistGraph(session);
    return plan;
}
