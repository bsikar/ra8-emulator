//! Tests for explicit confirmed history re-rooting, refusals, and unreachable object identification.
const std = @import("std");
const ra8 = @import("ra8");
const reroot = ra8.session.history_reroot;
const CheckpointEntry = reroot.CheckpointEntry;
const Position = ra8.chip.core.scheduler.Position;
const ObjectId = ra8.session.history_object_id.ObjectId;
const manifest_mod = ra8.session.history_manifest;
const branch_mod = ra8.session.history_branch;

test "reroot refuses without explicit confirmation flag" {
    const allocator = std.testing.allocator;

    const manifest0 = manifest_mod.Manifest{
        .position = Position{ .r = 0 },
        .checkpoint_id = 0,
        .picture = null,
        .pages = &.{},
        .blobs = &.{},
        .root_hash = ObjectId.zero,
    };

    const checkpoints = [_]CheckpointEntry{
        .{ .id = 0, .position = Position{ .r = 0 }, .manifest = &manifest0 },
    };

    const res = reroot.planReroot(allocator, 0, false, &checkpoints, null, &.{});
    try std.testing.expectError(reroot.Error.NotConfirmed, res);
}

test "reroot refuses if target checkpoint does not exist" {
    const allocator = std.testing.allocator;

    const manifest0 = manifest_mod.Manifest{
        .position = Position{ .r = 0 },
        .checkpoint_id = 0,
        .picture = null,
        .pages = &.{},
        .blobs = &.{},
        .root_hash = ObjectId.zero,
    };

    const checkpoints = [_]CheckpointEntry{
        .{ .id = 0, .position = Position{ .r = 0 }, .manifest = &manifest0 },
    };

    const res = reroot.planReroot(allocator, 999, true, &checkpoints, null, &.{});
    try std.testing.expectError(reroot.Error.NoSuchCheckpoint, res);
}

test "reroot refuses if history before target contains a pin" {
    const allocator = std.testing.allocator;

    const manifest0 = manifest_mod.Manifest{
        .position = Position{ .r = 10 },
        .checkpoint_id = 0,
        .picture = null,
        .pages = &.{},
        .blobs = &.{},
        .root_hash = ObjectId.zero,
    };
    const manifest1 = manifest_mod.Manifest{
        .position = Position{ .r = 20 },
        .checkpoint_id = 1,
        .picture = null,
        .pages = &.{},
        .blobs = &.{},
        .root_hash = ObjectId.zero,
    };

    // Checkpoint 0 is pinned and sits before new root at Checkpoint 1
    const checkpoints = [_]CheckpointEntry{
        .{ .id = 0, .position = Position{ .r = 10 }, .manifest = &manifest0, .pinned = true },
        .{ .id = 1, .position = Position{ .r = 20 }, .manifest = &manifest1, .pinned = false },
    };

    const res = reroot.planReroot(allocator, 1, true, &checkpoints, null, &.{});
    try std.testing.expectError(reroot.Error.PinnedHistory, res);
}

test "reroot refuses if branch graph has pinned branch before new root" {
    const allocator = std.testing.allocator;

    var graph = try branch_mod.BranchGraph.init(allocator);
    defer graph.deinit();

    // Create a child branch at round 10 with pins = 1
    const child_id = try graph.addBranch(0, Position{ .r = 10 }, .base, 0);
    var node = graph.get(child_id).?;
    node.pins = 1;
    node.recorded_end = Position{ .r = 15 };
    try graph.insertNode(node);

    const manifest0 = manifest_mod.Manifest{
        .position = Position{ .r = 10 },
        .checkpoint_id = 0,
        .picture = null,
        .pages = &.{},
        .blobs = &.{},
        .root_hash = ObjectId.zero,
    };
    const manifest1 = manifest_mod.Manifest{
        .position = Position{ .r = 50 },
        .checkpoint_id = 1,
        .picture = null,
        .pages = &.{},
        .blobs = &.{},
        .root_hash = ObjectId.zero,
    };

    const checkpoints = [_]CheckpointEntry{
        .{ .id = 0, .position = Position{ .r = 10 }, .manifest = &manifest0 },
        .{ .id = 1, .position = Position{ .r = 50 }, .manifest = &manifest1 },
    };

    const res = reroot.planReroot(allocator, 1, true, &checkpoints, &graph, &.{});
    try std.testing.expectError(reroot.Error.PinnedHistory, res);
}

test "reroot drops earlier history and correctly isolates unreachable objects" {
    const allocator = std.testing.allocator;

    const obj_unique_to_cp0 = ObjectId.compute("unique_to_cp0");
    const obj_shared_0_and_1 = ObjectId.compute("shared_0_and_1");
    const obj_unique_to_cp1 = ObjectId.compute("unique_to_cp1");

    // CP 0 (round 10) holds: obj_unique_to_cp0, obj_shared_0_and_1
    var pages0 = [_]manifest_mod.PageRef{
        .{ .space = .cpu0_sram, .page_index = 0, .object = obj_unique_to_cp0 },
        .{ .space = .cpu0_sram, .page_index = 1, .object = obj_shared_0_and_1 },
    };
    const manifest0 = manifest_mod.Manifest{
        .position = Position{ .r = 10 },
        .checkpoint_id = 0,
        .picture = null,
        .pages = &pages0,
        .blobs = &.{},
        .root_hash = ObjectId.zero,
    };

    // CP 1 (round 20 - NEW ROOT) holds: obj_shared_0_and_1, obj_unique_to_cp1
    var pages1 = [_]manifest_mod.PageRef{
        .{ .space = .cpu0_sram, .page_index = 1, .object = obj_shared_0_and_1 },
        .{ .space = .cpu0_sram, .page_index = 2, .object = obj_unique_to_cp1 },
    };
    const manifest1 = manifest_mod.Manifest{
        .position = Position{ .r = 20 },
        .checkpoint_id = 1,
        .picture = null,
        .pages = &pages1,
        .blobs = &.{},
        .root_hash = ObjectId.zero,
    };

    const checkpoints = [_]CheckpointEntry{
        .{ .id = 0, .position = Position{ .r = 10 }, .manifest = &manifest0 },
        .{ .id = 1, .position = Position{ .r = 20 }, .manifest = &manifest1 },
    };

    var plan = try reroot.planReroot(allocator, 1, true, &checkpoints, null, &.{});
    defer plan.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), plan.new_root_checkpoint);
    try std.testing.expectEqual(@as(u64, 20), plan.new_root_position.r);

    // CP 0 must be dropped
    try std.testing.expectEqual(@as(usize, 1), plan.dropped_checkpoints.len);
    try std.testing.expectEqual(@as(u32, 0), plan.dropped_checkpoints[0]);

    // Only obj_unique_to_cp0 should be unreachable!
    // obj_shared_0_and_1 is retained in CP 1, so it is NOT unreachable.
    try std.testing.expectEqual(@as(usize, 1), plan.unreachable_objects.len);
    try std.testing.expect(plan.unreachable_objects[0].eql(obj_unique_to_cp0));
}

test "reroot preserves child branches and their objects intact" {
    const allocator = std.testing.allocator;

    var graph = try branch_mod.BranchGraph.init(allocator);
    defer graph.deinit();

    // Branch 1 forks from Branch 0 at round 10
    const b1_id = try graph.addBranch(0, Position{ .branch = 0, .r = 10 }, .writes, 1000);
    var b1_node = graph.get(b1_id).?;
    b1_node.recorded_end = Position{ .branch = b1_id, .r = 30 };
    try graph.insertNode(b1_node);

    const obj_cp0 = ObjectId.compute("unique_cp0");
    const obj_b1 = ObjectId.compute("unique_b1");
    const obj_cp1 = ObjectId.compute("unique_cp1");

    var pages0 = [_]manifest_mod.PageRef{.{ .space = .cpu0_sram, .page_index = 0, .object = obj_cp0 }};
    const manifest0 = manifest_mod.Manifest{
        .position = Position{ .branch = 0, .r = 10 },
        .checkpoint_id = 0,
        .picture = null,
        .pages = &pages0,
        .blobs = &.{},
        .root_hash = ObjectId.zero,
    };

    var pages1 = [_]manifest_mod.PageRef{.{ .space = .cpu0_sram, .page_index = 1, .object = obj_cp1 }};
    const manifest1 = manifest_mod.Manifest{
        .position = Position{ .branch = 0, .r = 50 },
        .checkpoint_id = 1,
        .picture = null,
        .pages = &pages1,
        .blobs = &.{},
        .root_hash = ObjectId.zero,
    };

    var pages2 = [_]manifest_mod.PageRef{.{ .space = .cpu0_sram, .page_index = 2, .object = obj_b1 }};
    const manifest2 = manifest_mod.Manifest{
        .position = Position{ .branch = b1_id, .r = 20 },
        .checkpoint_id = 2,
        .picture = null,
        .pages = &pages2,
        .blobs = &.{},
        .root_hash = ObjectId.zero,
    };

    const checkpoints = [_]CheckpointEntry{
        .{ .id = 0, .position = Position{ .branch = 0, .r = 10 }, .manifest = &manifest0 },
        .{ .id = 1, .position = Position{ .branch = 0, .r = 50 }, .manifest = &manifest1 },
        .{ .id = 2, .position = Position{ .branch = b1_id, .r = 20 }, .manifest = &manifest2 },
    };

    // Re-root at Checkpoint 1 (round 50 on Branch 0)
    var plan = try reroot.planReroot(allocator, 1, true, &checkpoints, &graph, &.{});
    defer plan.deinit(allocator);

    // Only Checkpoint 0 should be dropped
    try std.testing.expectEqual(@as(usize, 1), plan.dropped_checkpoints.len);
    try std.testing.expectEqual(@as(u32, 0), plan.dropped_checkpoints[0]);

    // Checkpoint 2 on Branch 1 is preserved intact
    for (plan.dropped_checkpoints) |d| {
        try std.testing.expect(d != 2);
    }

    // Branch 1 is NOT dropped
    try std.testing.expectEqual(@as(usize, 0), plan.dropped_branches.len);

    // Branch 1's unique object is NOT unreachable
    try std.testing.expectEqual(@as(usize, 1), plan.unreachable_objects.len);
    try std.testing.expect(plan.unreachable_objects[0].eql(obj_cp0));
}
