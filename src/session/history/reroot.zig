//! Explicit confirmed history re-rooting.
//!
//! Re-roots the history graph at a selected checkpoint: history strictly
//! before the new root is dropped, and objects referenced solely by the
//! discarded history are identified as unreachable for reclamation.
//!
//! Protections & Refusals:
//!  - Refuses without explicit confirmation flag (Error.NotConfirmed).
//!  - Refuses if any pinned bookmark or pinned branch exists prior to the
//!    new root (Error.PinnedHistory).
//!  - Refuses if the target checkpoint does not exist (Error.NoSuchCheckpoint).
const std = @import("std");
const ObjectId = @import("object_id.zig").ObjectId;
const Position = @import("position.zig").Position;
const manifest_mod = @import("manifest.zig");
const branch_mod = @import("branch.zig");

pub const Error = error{
    NotConfirmed,
    NoSuchCheckpoint,
    PinnedHistory,
    OutOfMemory,
};

pub const CheckpointEntry = struct {
    id: u32,
    position: Position,
    manifest: *const manifest_mod.Manifest,
    pinned: bool = false,
};

pub const RerootPlan = struct {
    new_root_checkpoint: u32,
    new_root_position: Position,
    dropped_checkpoints: []u32,
    dropped_branches: []branch_mod.BranchId,
    unreachable_objects: []ObjectId,

    pub fn deinit(self: *RerootPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.dropped_checkpoints);
        allocator.free(self.dropped_branches);
        allocator.free(self.unreachable_objects);
        self.* = undefined;
    }
};

fn checkPinProtections(
    target_pos: Position,
    checkpoints: []const CheckpointEntry,
    graph: ?*const branch_mod.BranchGraph,
) Error!void {
    for (checkpoints) |cp| {
        if (branch_mod.scalarOrder(cp.position, target_pos) == .lt) {
            if (cp.pinned) return Error.PinnedHistory;
        }
    }

    if (graph) |g| {
        var it = g.nodes.valueIterator();
        while (it.next()) |node| {
            if (node.pins > 0) {
                if (branch_mod.scalarOrder(node.recorded_end, target_pos) == .lt or
                    branch_mod.scalarOrder(node.fork_at, target_pos) == .lt)
                {
                    return Error.PinnedHistory;
                }
            }
        }
    }
}

fn collectUnreachableObjects(
    allocator: std.mem.Allocator,
    target_pos: Position,
    checkpoints: []const CheckpointEntry,
    extra_live_objects: []const ObjectId,
) ![]ObjectId {
    var kept_set = std.AutoHashMap([16]u8, void).init(allocator);
    defer kept_set.deinit();

    for (checkpoints) |cp| {
        if (branch_mod.scalarOrder(cp.position, target_pos) != .lt) {
            for (cp.manifest.pages) |p| try kept_set.put(p.object.bytes, {});
            for (cp.manifest.blobs) |b| try kept_set.put(b.object.bytes, {});
            if (cp.manifest.picture) |pic| try kept_set.put(pic.bytes, {});
        }
    }
    for (extra_live_objects) |obj| {
        try kept_set.put(obj.bytes, {});
    }

    var dead_map = std.AutoHashMap([16]u8, ObjectId).init(allocator);
    defer dead_map.deinit();

    for (checkpoints) |cp| {
        if (branch_mod.scalarOrder(cp.position, target_pos) == .lt) {
            for (cp.manifest.pages) |p| {
                if (!kept_set.contains(p.object.bytes)) {
                    try dead_map.put(p.object.bytes, p.object);
                }
            }
            for (cp.manifest.blobs) |b| {
                if (!kept_set.contains(b.object.bytes)) {
                    try dead_map.put(b.object.bytes, b.object);
                }
            }
            if (cp.manifest.picture) |pic| {
                if (!kept_set.contains(pic.bytes)) {
                    try dead_map.put(pic.bytes, pic);
                }
            }
        }
    }

    const dead_list = try allocator.alloc(ObjectId, dead_map.count());
    var idx: usize = 0;
    var val_it = dead_map.valueIterator();
    while (val_it.next()) |obj| {
        dead_list[idx] = obj.*;
        idx += 1;
    }
    return dead_list;
}

/// Computes the re-root plan, validating confirmations and pin protections.
pub fn planReroot(
    allocator: std.mem.Allocator,
    target_id: u32,
    confirm: bool,
    checkpoints: []const CheckpointEntry,
    graph: ?*const branch_mod.BranchGraph,
    extra_live_objects: []const ObjectId,
) Error!RerootPlan {
    if (!confirm) return Error.NotConfirmed;

    var target_idx: ?usize = null;
    for (checkpoints, 0..) |cp, i| {
        if (cp.id == target_id) {
            target_idx = i;
            break;
        }
    }
    const t_idx = target_idx orelse return Error.NoSuchCheckpoint;
    const target_cp = checkpoints[t_idx];

    try checkPinProtections(target_cp.position, checkpoints, graph);

    var drop_cp_count: usize = 0;
    for (checkpoints) |cp| {
        if (branch_mod.scalarOrder(cp.position, target_cp.position) == .lt) {
            drop_cp_count += 1;
        }
    }

    const dropped_cps = try allocator.alloc(u32, drop_cp_count);
    errdefer allocator.free(dropped_cps);
    var d_idx: usize = 0;
    for (checkpoints) |cp| {
        if (branch_mod.scalarOrder(cp.position, target_cp.position) == .lt) {
            dropped_cps[d_idx] = cp.id;
            d_idx += 1;
        }
    }

    var dropped_branches_list: std.ArrayList(branch_mod.BranchId) = .empty;
    defer dropped_branches_list.deinit(allocator);

    if (graph) |g| {
        var it = g.nodes.valueIterator();
        while (it.next()) |node| {
            if (node.id != branch_mod.root_branch_id) {
                if (branch_mod.scalarOrder(node.recorded_end, target_cp.position) == .lt) {
                    try dropped_branches_list.append(allocator, node.id);
                }
            }
        }
    }
    const dropped_branches = try dropped_branches_list.toOwnedSlice(allocator);
    errdefer allocator.free(dropped_branches);

    const unreachable_list = try collectUnreachableObjects(
        allocator,
        target_cp.position,
        checkpoints,
        extra_live_objects,
    );

    return .{
        .new_root_checkpoint = target_id,
        .new_root_position = target_cp.position,
        .dropped_checkpoints = dropped_cps,
        .dropped_branches = dropped_branches,
        .unreachable_objects = unreachable_list,
    };
}
