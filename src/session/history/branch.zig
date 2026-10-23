//! The history branch graph: branch hierarchy, line ownership, canonical
//! position resolution, and line-aware position ordering.
//!
//! A line is a leaf branch plus its ancestors' prefixes back to root 0.
//! A branch's own segment starts at its fork_at; ancestors' prefixes before
//! that belong to the ancestors. Position.branch names the branch whose own
//! segment owns the point. On a line, canonicalize maps a point to its owning
//! ancestor. Two positions compare by (r, phase, o, gap) only when both lie
//! on one line; otherwise error.OtherLine.
const std = @import("std");
const history_position = @import("position.zig");
const history_record = @import("record.zig");

pub const Position = history_position.Position;
pub const ForkReason = history_record.ForkReason;
pub const BranchId = u32;
pub const root_branch_id: BranchId = 0;

pub const Error = error{
    OtherLine,
    NoSuchBranch,
    BranchActive,
    BranchPinned,
    BranchKept,
    RootBranchProtected,
    BranchAlreadyExists,
    InvalidForkPosition,
    OutOfMemory,
};

pub const BranchNode = struct {
    id: BranchId,
    parent: BranchId,
    fork_at: Position,
    reason: ForkReason,
    created_ns: u64 = 0,
    recorded_end: Position,
    pins: u16 = 0,
    is_live: bool = false,
    kept: bool = false,
    pruned_tail: bool = false,
};

pub const BranchGraph = struct {
    allocator: std.mem.Allocator,
    nodes: std.AutoHashMap(BranchId, BranchNode),
    active_branch: BranchId = root_branch_id,
    next_branch_id: BranchId = 1,

    /// Initializes a new branch graph containing the default base line root branch 0.
    pub fn init(allocator: std.mem.Allocator) !BranchGraph {
        var graph = BranchGraph{
            .allocator = allocator,
            .nodes = std.AutoHashMap(BranchId, BranchNode).init(allocator),
        };
        const root_pos = Position{
            .branch = root_branch_id,
            .r = 0,
            .phase = .cpu0,
            .o = 0,
            .gap = .retired,
        };
        try graph.nodes.put(root_branch_id, .{
            .id = root_branch_id,
            .parent = root_branch_id,
            .fork_at = root_pos,
            .reason = .base,
            .created_ns = 0,
            .recorded_end = root_pos,
            .is_live = true,
        });
        return graph;
    }

    /// Releases all resources allocated by the branch graph.
    pub fn deinit(self: *BranchGraph) void {
        self.nodes.deinit();
    }

    /// Looks up a branch node by its identifier.
    pub fn get(self: *const BranchGraph, id: BranchId) ?BranchNode {
        return self.nodes.get(id);
    }

    /// Inserts or updates an existing branch node, adjusting next_branch_id accordingly.
    pub fn insertNode(self: *BranchGraph, node: BranchNode) !void {
        try self.nodes.put(node.id, node);
        if (node.id >= self.next_branch_id) {
            self.next_branch_id = node.id + 1;
        }
    }

    /// Allocates and appends a new child branch forked from parent_id at fork_at.
    pub fn addBranch(
        self: *BranchGraph,
        parent_id: BranchId,
        fork_at: Position,
        reason: ForkReason,
        created_ns: u64,
    ) !BranchId {
        if (!self.nodes.contains(parent_id)) return Error.NoSuchBranch;
        const id = self.next_branch_id;
        self.next_branch_id += 1;
        const node: BranchNode = .{
            .id = id,
            .parent = parent_id,
            .fork_at = fork_at,
            .reason = reason,
            .created_ns = created_ns,
            .recorded_end = fork_at,
            .is_live = false,
        };
        try self.nodes.put(id, node);
        return id;
    }

    /// Returns true if ancestor is equal to desc or an ancestor along desc's lineage.
    pub fn isAncestorOrSelf(self: *const BranchGraph, ancestor: BranchId, desc: BranchId) bool {
        if (ancestor == desc) return true;
        var curr = desc;
        while (curr != root_branch_id) {
            const node = self.nodes.get(curr) orelse return false;
            curr = node.parent;
            if (curr == ancestor) return true;
        }
        return ancestor == root_branch_id;
    }

    /// Finds the immediate child of ancestor on the path leading to desc.
    pub fn childLeadingTo(self: *const BranchGraph, ancestor: BranchId, desc: BranchId) ?BranchId {
        if (ancestor == desc) return null;
        var prev = desc;
        var curr = desc;
        while (curr != root_branch_id) {
            const node = self.nodes.get(curr) orelse return null;
            if (node.parent == ancestor) return prev;
            prev = node.parent;
            curr = node.parent;
        }
        return null;
    }

    /// Maps a position to its owning segment ancestor along the line ending at line_leaf.
    pub fn canonicalize(self: *const BranchGraph, line_leaf: BranchId, p: Position) Error!Position {
        if (!self.nodes.contains(line_leaf)) return Error.NoSuchBranch;
        if (p.branch != line_leaf and p.branch != root_branch_id) {
            if (!self.isAncestorOrSelf(p.branch, line_leaf)) return Error.OtherLine;
        }
        if (p.branch != line_leaf) {
            if (self.childLeadingTo(p.branch, line_leaf)) |child_id| {
                const child_node = self.nodes.get(child_id).?;
                if (scalarOrder(p, child_node.fork_at) != .lt) {
                    return Error.OtherLine;
                }
            }
        }
        var curr = line_leaf;
        while (curr != root_branch_id) {
            const node = self.nodes.get(curr).?;
            if (scalarOrder(p, node.fork_at) != .lt) {
                return .{
                    .branch = curr,
                    .r = p.r,
                    .phase = p.phase,
                    .o = p.o,
                    .gap = p.gap,
                };
            }
            curr = node.parent;
        }
        return .{
            .branch = root_branch_id,
            .r = p.r,
            .phase = p.phase,
            .o = p.o,
            .gap = p.gap,
        };
    }

    /// Orders two positions along the execution line identified by line_leaf.
    pub fn compareOnLine(
        self: *const BranchGraph,
        line_leaf: BranchId,
        a: Position,
        b: Position,
    ) Error!std.math.Order {
        const ca = try self.canonicalize(line_leaf, a);
        const cb = try self.canonicalize(line_leaf, b);
        return scalarOrder(ca, cb);
    }

    /// Compares two positions, resolving line ancestry and refusing cross-line points.
    pub fn compare(self: *const BranchGraph, a: Position, b: Position) Error!std.math.Order {
        if (a.branch == b.branch) {
            if (a.branch == root_branch_id) return scalarOrder(a, b);
            const node = self.nodes.get(a.branch) orelse return Error.NoSuchBranch;
            if (scalarOrder(a, node.fork_at) == .lt or scalarOrder(b, node.fork_at) == .lt) {
                return self.compareOnLine(a.branch, a, b);
            }
            return scalarOrder(a, b);
        }
        if (self.isAncestorOrSelf(a.branch, b.branch)) {
            return self.compareOnLine(b.branch, a, b);
        }
        if (self.isAncestorOrSelf(b.branch, a.branch)) {
            return self.compareOnLine(a.branch, a, b);
        }
        return Error.OtherLine;
    }
};

/// Orders two positions lexicographically by (r, phase, o, gap), ignoring branch.
pub fn scalarOrder(a: Position, b: Position) std.math.Order {
    inline for (.{ "r", "phase", "o", "gap" }) |field_name| {
        const left = @field(a, field_name);
        const right = @field(b, field_name);
        const result = if (@typeInfo(@TypeOf(left)) == .@"enum")
            std.math.order(@backingInt(left), @backingInt(right))
        else
            std.math.order(left, right);
        if (result != .eq) return result;
    }
    return .eq;
}
