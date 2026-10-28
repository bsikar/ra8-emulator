//! Logarithmic and age-based checkpoint thinning.
//!
//! Thins checkpoints along an execution line using a logarithmic density curve
//! around the cursor (dense near the cursor, exponentially sparser away, like rr),
//! supplemented by age-based thinning.
//!
//! Invariants:
//!  - Never thins below max_replay_gap: the distance in rounds between any two
//!    adjacent surviving checkpoints never exceeds max_replay_gap.
//!  - Never drops a pinned bookmark's checkpoint.
//!  - Never drops a branch's fork-point base checkpoint needed to replay a child line.
//!  - Retains all checkpoint pictures attached to kept checkpoints.
const std = @import("std");
const ObjectId = @import("object_id.zig").ObjectId;
const Position = @import("position.zig").Position;
const branch_mod = @import("branch.zig");

pub const CheckpointRef = struct {
    id: u32,
    position: Position,
    created_ns: u64 = 0,
    pinned: bool = false,
    fork_base: bool = false,
    picture: ?ObjectId = null,
};

pub const ThinningOptions = struct {
    max_replay_gap: u64,
    dense_window_rounds: u64 = 16,
    base_window_rounds: u64 = 32,
    now_ns: u64 = 0,
    age_threshold_ns: ?u64 = null,
    age_gap_multiplier: u32 = 2,
};

pub const ThinningPlan = struct {
    dropped_checkpoints: []u32,
    kept_checkpoints: []u32,
    kept_pictures: []ObjectId,

    pub fn deinit(self: *ThinningPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.dropped_checkpoints);
        allocator.free(self.kept_checkpoints);
        allocator.free(self.kept_pictures);
        self.* = undefined;
    }
};

/// Calculates the target spacing between checkpoints at a given distance from the cursor.
pub fn calculateTargetGap(
    cp_round: u64,
    cursor_round: u64,
    created_ns: u64,
    options: ThinningOptions,
) u64 {
    const dist = if (cp_round > cursor_round) cp_round - cursor_round else cursor_round - cp_round;
    if (dist < options.dense_window_rounds) return 1;

    const span = dist - options.dense_window_rounds;
    const window = @max(@as(u64, 1), options.base_window_rounds);
    const tier = span / window;
    const shift = @min(tier, @as(u64, 16));
    var gap = @as(u64, 1) << @intCast(shift);

    if (options.age_threshold_ns) |thresh| {
        if (options.now_ns >= created_ns and (options.now_ns - created_ns) > thresh) {
            gap = std.math.mul(u64, gap, options.age_gap_multiplier) catch options.max_replay_gap;
        }
    }

    return @min(gap, options.max_replay_gap);
}

/// Marks fork-point base checkpoints for all children of line_branch in the branch graph.
pub fn markForkBases(checkpoints: []CheckpointRef, graph: *const branch_mod.BranchGraph) void {
    var it = graph.nodes.valueIterator();
    while (it.next()) |node| {
        if (node.id == branch_mod.root_branch_id) continue;
        var best_idx: ?usize = null;
        for (checkpoints, 0..) |cp, i| {
            if (cp.position.branch != node.parent) continue;
            if (branch_mod.scalarOrder(cp.position, node.fork_at) != .gt) {
                best_idx = i;
            }
        }
        if (best_idx) |idx| {
            checkpoints[idx].fork_base = true;
        }
    }
}

fn computeKeptMask(
    allocator: std.mem.Allocator,
    checkpoints: []const CheckpointRef,
    cursor: Position,
    options: ThinningOptions,
) ![]bool {
    var kept_mask = try allocator.alloc(bool, checkpoints.len);
    @memset(kept_mask, false);

    // Root (first) and end (last) checkpoints are always anchors
    kept_mask[0] = true;
    kept_mask[checkpoints.len - 1] = true;

    // Pin and fork-base checkpoints are mandatory survivors
    for (checkpoints, 0..) |cp, i| {
        if (cp.pinned or cp.fork_base) {
            kept_mask[i] = true;
        }
    }

    var last_kept_idx: usize = 0;
    for (checkpoints[1..], 1..) |cp, i| {
        if (kept_mask[i]) {
            last_kept_idx = i;
            continue;
        }

        const last_kept = checkpoints[last_kept_idx];
        const gap_from_last = if (cp.position.r > last_kept.position.r)
            cp.position.r - last_kept.position.r
        else
            0;

        const next_anchor_gap = if (i + 1 < checkpoints.len)
            checkpoints[i + 1].position.r - last_kept.position.r
        else
            gap_from_last;

        if (next_anchor_gap > options.max_replay_gap) {
            kept_mask[i] = true;
            last_kept_idx = i;
            continue;
        }

        const target_gap = calculateTargetGap(cp.position.r, cursor.r, cp.created_ns, options);
        if (gap_from_last >= target_gap) {
            kept_mask[i] = true;
            last_kept_idx = i;
        }
    }
    return kept_mask;
}

fn assemblePlan(
    allocator: std.mem.Allocator,
    checkpoints: []const CheckpointRef,
    kept_mask: []const bool,
) !ThinningPlan {
    var drop_count: usize = 0;
    var keep_count: usize = 0;
    var pic_count: usize = 0;

    for (checkpoints, 0..) |cp, i| {
        if (kept_mask[i]) {
            keep_count += 1;
            if (cp.picture != null) pic_count += 1;
        } else {
            drop_count += 1;
        }
    }

    const dropped = try allocator.alloc(u32, drop_count);
    errdefer allocator.free(dropped);
    const kept = try allocator.alloc(u32, keep_count);
    errdefer allocator.free(kept);
    const pictures = try allocator.alloc(ObjectId, pic_count);
    errdefer allocator.free(pictures);

    var d_idx: usize = 0;
    var k_idx: usize = 0;
    var p_idx: usize = 0;

    for (checkpoints, 0..) |cp, i| {
        if (kept_mask[i]) {
            kept[k_idx] = cp.id;
            k_idx += 1;
            if (cp.picture) |pic| {
                pictures[p_idx] = pic;
                p_idx += 1;
            }
        } else {
            dropped[d_idx] = cp.id;
            d_idx += 1;
        }
    }

    return .{
        .dropped_checkpoints = dropped,
        .kept_checkpoints = kept,
        .kept_pictures = pictures,
    };
}

/// Computes the thinning plan, selecting checkpoints to drop while guaranteeing
/// protections and the max_replay_gap boundary between survivors.
pub fn planThinning(
    allocator: std.mem.Allocator,
    checkpoints: []const CheckpointRef,
    cursor: Position,
    options: ThinningOptions,
) !ThinningPlan {
    if (checkpoints.len == 0) {
        return .{
            .dropped_checkpoints = try allocator.alloc(u32, 0),
            .kept_checkpoints = try allocator.alloc(u32, 0),
            .kept_pictures = try allocator.alloc(ObjectId, 0),
        };
    }

    const kept_mask = try computeKeptMask(allocator, checkpoints, cursor, options);
    defer allocator.free(kept_mask);

    return assemblePlan(allocator, checkpoints, kept_mask);
}
