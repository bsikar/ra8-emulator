//! Tests for logarithmic thinning density, pin/picture preservation, and max_replay_gap compliance.
const std = @import("std");
const ra8 = @import("ra8");
const thinning = ra8.session.history_thinning;
const CheckpointRef = thinning.CheckpointRef;
const ThinningOptions = thinning.ThinningOptions;
const Position = ra8.chip.core.scheduler.Position;
const ObjectId = ra8.session.history_object_id.ObjectId;
const branch_mod = ra8.session.history_branch;

test "thinning density shape keeps dense checkpoints near cursor and thins farther away" {
    const allocator = std.testing.allocator;

    // 51 checkpoints spaced 10 rounds apart: rounds 0, 10, 20, ... 500
    var checkpoints: [51]CheckpointRef = undefined;
    for (0..51) |i| {
        checkpoints[i] = .{
            .id = @intCast(i),
            .position = Position{ .r = @intCast(i * 10) },
        };
    }

    // Cursor positioned at round 250 (index 25)
    const cursor = Position{ .r = 250 };
    const options = ThinningOptions{
        .max_replay_gap = 80,
        .dense_window_rounds = 40, // [210..290] is dense window
        .base_window_rounds = 40,
    };

    var plan = try thinning.planThinning(allocator, &checkpoints, cursor, options);
    defer plan.deinit(allocator);

    // Near cursor: checkpoints at rounds 220, 230, 240, 250, 260, 270, 280 should all be kept
    for (22..29) |i| {
        var found = false;
        for (plan.kept_checkpoints) |k| {
            if (k == i) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }

    // Far from cursor: at least some checkpoints must be dropped
    try std.testing.expect(plan.dropped_checkpoints.len > 0);
}

test "thinning pins and pictures are never evicted" {
    const allocator = std.testing.allocator;

    var checkpoints: [20]CheckpointRef = undefined;
    for (0..20) |i| {
        checkpoints[i] = .{
            .id = @intCast(i),
            .position = Position{ .r = @intCast(i * 10) },
        };
    }

    // Pin checkpoint 3 (round 30), which sits far from cursor (round 180)
    checkpoints[3].pinned = true;
    const pic_id = ObjectId.compute("bookmark_pic_3");
    checkpoints[3].picture = pic_id;

    const cursor = Position{ .r = 180 };
    const options = ThinningOptions{
        .max_replay_gap = 100,
        .dense_window_rounds = 20,
        .base_window_rounds = 20,
    };

    var plan = try thinning.planThinning(allocator, &checkpoints, cursor, options);
    defer plan.deinit(allocator);

    // Verify pinned checkpoint 3 was kept
    var pinned_kept = false;
    for (plan.kept_checkpoints) |k| {
        if (k == 3) pinned_kept = true;
    }
    try std.testing.expect(pinned_kept);

    // Verify pinned checkpoint is never in dropped list
    for (plan.dropped_checkpoints) |d| {
        try std.testing.expect(d != 3);
    }

    // Verify its picture was preserved in kept_pictures
    var pic_found = false;
    for (plan.kept_pictures) |pic| {
        if (pic.eql(pic_id)) pic_found = true;
    }
    try std.testing.expect(pic_found);
}

test "thinning never exceeds max_replay_gap between surviving checkpoints" {
    const allocator = std.testing.allocator;

    var checkpoints: [100]CheckpointRef = undefined;
    for (0..100) |i| {
        checkpoints[i] = .{
            .id = @intCast(i),
            .position = Position{ .r = @intCast(i * 10) },
        };
    }

    const cursor = Position{ .r = 0 };
    const max_gap: u64 = 50;
    const options = ThinningOptions{
        .max_replay_gap = max_gap,
        .dense_window_rounds = 10,
        .base_window_rounds = 10,
    };

    var plan = try thinning.planThinning(allocator, &checkpoints, cursor, options);
    defer plan.deinit(allocator);

    try std.testing.expect(plan.kept_checkpoints.len >= 2);

    // Verify distance between adjacent surviving checkpoints never exceeds max_replay_gap
    for (0..plan.kept_checkpoints.len - 1) |i| {
        const id_a = plan.kept_checkpoints[i];
        const id_b = plan.kept_checkpoints[i + 1];
        const r_a = checkpoints[id_a].position.r;
        const r_b = checkpoints[id_b].position.r;
        try std.testing.expect(r_b > r_a);
        const gap = r_b - r_a;
        try std.testing.expect(gap <= max_gap);
    }
}

test "thinning markForkBases marks parent line and ignores unrelated branch forks" {
    const allocator = std.testing.allocator;

    var graph = try branch_mod.BranchGraph.init(allocator);
    defer graph.deinit();

    // Branch 1 forks from root Branch 0 at round 50
    const b1_fork = Position{ .branch = 0, .r = 50 };
    const b1 = try graph.addBranch(0, b1_fork, .writes, 1000);

    // Branch 2 forks from Branch 1 at round 500 (unrelated to Branch 0 points)
    const b2_fork = Position{ .branch = b1, .r = 500 };
    _ = try graph.addBranch(b1, b2_fork, .writes, 2000);

    var checkpoints: [30]CheckpointRef = undefined;
    for (0..30) |i| {
        checkpoints[i] = .{
            .id = @intCast(i),
            .position = Position{ .branch = 0, .r = @intCast(i * 10) },
        };
    }

    // Call markForkBases directly
    thinning.markForkBases(&checkpoints, &graph);

    // Checkpoint 5 (r = 50 on Branch 0) must be marked as fork_base for Branch 1
    try std.testing.expect(checkpoints[5].fork_base);

    // Checkpoint 29 (r = 290 on Branch 0) must NOT be marked for Branch 2's fork at 500
    try std.testing.expect(!checkpoints[29].fork_base);

    // Assert only checkpoint 5 was marked
    for (checkpoints, 0..) |cp, idx| {
        if (idx == 5) {
            try std.testing.expect(cp.fork_base);
        } else {
            try std.testing.expect(!cp.fork_base);
        }
    }

    const cursor = Position{ .branch = 0, .r = 250 };
    const options = ThinningOptions{
        .max_replay_gap = 100,
        .dense_window_rounds = 20,
        .base_window_rounds = 20,
    };

    var plan = try thinning.planThinning(allocator, &checkpoints, cursor, options);
    defer plan.deinit(allocator);

    var fork_base_kept = false;
    for (plan.kept_checkpoints) |k| {
        if (k == 5) fork_base_kept = true;
    }
    try std.testing.expect(fork_base_kept);

    for (plan.dropped_checkpoints) |d| {
        try std.testing.expect(d != 5);
    }
}
