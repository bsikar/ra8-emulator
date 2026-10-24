//! Tests for src/session/history/lifecycle.zig: branch listing, switching,
//! parent truncation vs leaf deletion, and crash-simulation recovery.
const std = @import("std");
const ra8 = @import("ra8");
const lifecycle = ra8.session.history_lifecycle;
const branch_mod = ra8.session.history_branch;
const fork_router_mod = ra8.session.history_fork_router;
const recover_mod = ra8.session.history_branches_recover;
const codec_mod = ra8.session.history_branches_codec;
const Position = lifecycle.Position;

fn pos(b: u32, r: u64) Position {
    return .{ .branch = b, .r = r, .phase = .cpu0, .o = 0, .gap = .retired };
}

test "branch list reports accurate counts, protection flags and sorted order" {
    const gpa = std.testing.allocator;
    var graph = try branch_mod.BranchGraph.init(gpa);
    defer graph.deinit();

    // Setup:
    // Root 0: fork_at=0, recorded_end=200
    // Child 1: parent=0, fork_at=50, recorded_end=150, kept=true
    // Child 2: parent=0, fork_at=100, recorded_end=180, pins=1
    // Grandchild 3: parent=1, fork_at=75, recorded_end=120
    var node0 = graph.get(0).?;
    node0.recorded_end = pos(0, 200);
    try graph.insertNode(node0);

    try graph.insertNode(.{
        .id = 1,
        .parent = 0,
        .fork_at = pos(0, 50),
        .reason = .writes,
        .recorded_end = pos(1, 150),
        .kept = true,
    });
    try graph.insertNode(.{
        .id = 2,
        .parent = 0,
        .fork_at = pos(0, 100),
        .reason = .buttons,
        .recorded_end = pos(2, 180),
        .pins = 1,
    });
    try graph.insertNode(.{
        .id = 3,
        .parent = 1,
        .fork_at = pos(1, 75),
        .reason = .keystrokes,
        .recorded_end = pos(3, 120),
    });

    const info = try lifecycle.list(gpa, &graph, 2);
    defer gpa.free(info);

    try std.testing.expectEqual(@as(usize, 4), info.len);

    // Sorted by ID:
    try std.testing.expectEqual(@as(u32, 0), info[0].id);
    try std.testing.expectEqual(@as(u32, 2), info[0].child_count); // 1 and 2
    try std.testing.expectEqual(false, info[0].is_live);
    try std.testing.expectEqual(false, info[0].is_pinned);

    try std.testing.expectEqual(@as(u32, 1), info[1].id);
    try std.testing.expectEqual(@as(u32, 1), info[1].child_count); // 3
    try std.testing.expectEqual(true, info[1].is_kept);
    try std.testing.expectEqual(false, info[1].is_live);

    try std.testing.expectEqual(@as(u32, 2), info[2].id);
    try std.testing.expectEqual(@as(u32, 0), info[2].child_count);
    try std.testing.expectEqual(true, info[2].is_live); // active_line was 2
    try std.testing.expectEqual(true, info[2].is_pinned);

    try std.testing.expectEqual(@as(u32, 3), info[3].id);
    try std.testing.expectEqual(@as(u32, 0), info[3].child_count);
    try std.testing.expectEqual(false, info[3].is_live);
}

test "branch remove enforces confirm and protections, truncates parent tail, removes leaf" {
    const gpa = std.testing.allocator;
    var graph = try branch_mod.BranchGraph.init(gpa);
    defer graph.deinit();

    var node0 = graph.get(0).?;
    node0.recorded_end = pos(0, 200);
    try graph.insertNode(node0);

    try graph.insertNode(.{
        .id = 1,
        .parent = 0,
        .fork_at = pos(0, 80),
        .reason = .writes,
        .recorded_end = pos(1, 150),
    });
    try graph.insertNode(.{
        .id = 2,
        .parent = 1,
        .fork_at = pos(1, 100),
        .reason = .buttons,
        .recorded_end = pos(2, 120),
    });

    var router = fork_router_mod.ForkRouter.init(gpa, &graph);
    defer router.deinit();
    router.active_line = 2;

    var session: lifecycle.Session = .{
        .live = undefined,
        .fork_router = &router,
    };

    // 1. Refuse without confirm
    try std.testing.expectError(lifecycle.Error.ConfirmRequired, lifecycle.removeBranch(&session, 1, false));

    // 2. Refuse live line
    try std.testing.expectError(lifecycle.Error.BranchActive, lifecycle.removeBranch(&session, 2, true));

    // 3. Parent removal: branch 1 has child 2 forking at r=100.
    // Branch 1's segment after r=100 is truncated; trunk up to 100 is kept.
    const plan1 = try lifecycle.removeBranch(&session, 1, true);
    try std.testing.expectEqual(lifecycle.TruncationKind.truncate_tail, plan1.kind);
    try std.testing.expectEqual(@as(u64, 100), plan1.new_recorded_end.r);
    try std.testing.expectEqual(@as(u32, 1), plan1.new_recorded_end.branch);

    const b1_after = graph.get(1).?;
    try std.testing.expect(b1_after.pruned_tail);
    try std.testing.expectEqual(@as(u64, 100), b1_after.recorded_end.r);

    // 4. Switch active line to 0, then remove leaf branch 2 whole
    router.active_line = 0;
    const plan2 = try lifecycle.removeBranch(&session, 2, true);
    try std.testing.expectEqual(lifecycle.TruncationKind.full_delete, plan2.kind);
    try std.testing.expect(graph.get(2) == null);

    // Now branch 1 has no children left, so removing it does a full delete
    const plan1_full = try lifecycle.removeBranch(&session, 1, true);
    try std.testing.expectEqual(lifecycle.TruncationKind.full_delete, plan1_full.kind);
    try std.testing.expect(graph.get(1) == null);

    // Root branch 0 without children cannot be deleted
    router.active_line = 99;
    var n0_final = graph.get(0).?;
    n0_final.is_live = false;
    try graph.insertNode(n0_final);
    try std.testing.expectError(lifecycle.Error.RootBranchProtected, lifecycle.removeBranch(&session, 0, true));
}

test "branch switch changes active line and persists updated graph" {
    const gpa = std.testing.allocator;
    var graph = try branch_mod.BranchGraph.init(gpa);
    defer graph.deinit();

    try graph.insertNode(.{
        .id = 1,
        .parent = 0,
        .fork_at = pos(0, 50),
        .reason = .writes,
        .recorded_end = pos(1, 150),
    });

    var router = fork_router_mod.ForkRouter.init(gpa, &graph);
    defer router.deinit();
    router.active_line = 0;

    var persisted_bytes: ?[]u8 = null;
    defer if (persisted_bytes) |b| gpa.free(b);

    const SinkHelper = struct {
        fn sinkFn(ctx: *anyopaque, encoded: []const u8) anyerror!void {
            const out_ptr: *?[]u8 = @ptrCast(@alignCast(ctx));
            if (out_ptr.*) |b| std.testing.allocator.free(b);
            out_ptr.* = try std.testing.allocator.dupe(u8, encoded);
        }
    };

    var session: lifecycle.Session = .{
        .live = undefined,
        .fork_router = &router,
        .graph_sink = .{
            .context = &persisted_bytes,
            .writeFn = SinkHelper.sinkFn,
        },
    };

    // Refuse unknown branch
    try std.testing.expectError(lifecycle.Error.NoSuchBranch, lifecycle.switchBranch(&session, null, 99));

    // Switch to branch 1
    try lifecycle.switchBranch(&session, null, 1);
    try std.testing.expectEqual(@as(u32, 1), router.active_line);
    try std.testing.expect(persisted_bytes != null);

    // Decode persisted bytes and confirm branch graph consistency
    var decoded = try codec_mod.decode(gpa, persisted_bytes.?);
    defer decoded.deinit();
    try std.testing.expect(decoded.get(1) != null);
}

test "crash simulation between log operations and branches.bin commit recovers coherent graph" {
    const gpa = std.testing.allocator;
    var graph = try branch_mod.BranchGraph.init(gpa);
    defer graph.deinit();

    var n0 = graph.get(0).?;
    n0.recorded_end = pos(0, 100);
    try graph.insertNode(n0);

    // State 1: commit valid baseline branches.bin
    const current_bytes = try codec_mod.encodeAlloc(&graph, gpa);
    defer gpa.free(current_bytes);

    // State 2: A fork happens and temp file is written.
    // Case A: Temp file was fully written and synced before crash interrupted atomic rename.
    try graph.insertNode(.{
        .id = 1,
        .parent = 0,
        .fork_at = pos(0, 50),
        .reason = .writes,
        .recorded_end = pos(1, 120),
    });
    const valid_temp_bytes = try codec_mod.encodeAlloc(&graph, gpa);
    defer gpa.free(valid_temp_bytes);

    // Recovery adopts valid temp file
    const res_a = try recover_mod.recover(gpa, current_bytes, valid_temp_bytes, null);
    var graph_a = res_a.graph;
    defer graph_a.deinit();
    try std.testing.expectEqual(recover_mod.Action.use_temp, res_a.action);
    try std.testing.expect(graph_a.get(1) != null);

    // Case B: Crash happened mid-write of temp file (corrupted/truncated temp file).
    const corrupted_temp = valid_temp_bytes[0 .. valid_temp_bytes.len / 2];
    const res_b = try recover_mod.recover(gpa, current_bytes, corrupted_temp, null);
    var graph_b = res_b.graph;
    defer graph_b.deinit();
    try std.testing.expectEqual(recover_mod.Action.use_current, res_b.action);
    // Baseline current file was preserved intact
    try std.testing.expect(graph_b.get(0) != null);
    try std.testing.expect(graph_b.get(1) == null);
}

test "recorded end of active line advances canonically per line and is reported by list" {
    const gpa = std.testing.allocator;
    var graph = try branch_mod.BranchGraph.init(gpa);
    defer graph.deinit();

    var router = fork_router_mod.ForkRouter.init(gpa, &graph);
    defer router.deinit();

    var session: lifecycle.Session = .{
        .live = undefined,
        .fork_router = &router,
    };

    // 1. Advance branch 0 from r=0 to r=2
    session.notePosition(pos(0, 2));
    try std.testing.expectEqual(@as(u64, 2), graph.get(0).?.recorded_end.r);

    const list0 = try lifecycle.list(gpa, &graph, router.active_line);
    defer gpa.free(list0);
    try std.testing.expectEqual(@as(usize, 1), list0.len);
    try std.testing.expectEqual(@as(u64, 2), list0[0].recorded_end.r);

    // 2. Fork branch 1 from branch 0 at r=1
    const b1 = try graph.addBranch(0, pos(0, 1), .writes, 1000);
    try std.testing.expectEqual(@as(u32, 1), b1);
    router.active_line = b1;
    graph.active_branch = b1;

    try std.testing.expectEqual(@as(u64, 1), graph.get(1).?.fork_at.r);
    try std.testing.expectEqual(@as(u64, 1), graph.get(1).?.recorded_end.r);

    // 3. Advance execution on branch 1 to r=5
    session.notePosition(pos(1, 5));

    try std.testing.expectEqual(@as(u64, 5), graph.get(1).?.recorded_end.r);
    try std.testing.expectEqual(@as(u64, 2), graph.get(0).?.recorded_end.r);

    // 4. Verify list reports the advanced recorded end for both branches
    const list1 = try lifecycle.list(gpa, &graph, router.active_line);
    defer gpa.free(list1);
    try std.testing.expectEqual(@as(usize, 2), list1.len);
    try std.testing.expectEqual(@as(u64, 2), list1[0].recorded_end.r);
    try std.testing.expectEqual(@as(u64, 5), list1[1].recorded_end.r);
    try std.testing.expect(list1[1].is_live);
    try std.testing.expect(!list1[0].is_live);

    // 5. Switch back to branch 0 and advance it to r=8
    router.active_line = 0;
    graph.active_branch = 0;
    session.notePosition(pos(0, 8));

    try std.testing.expectEqual(@as(u64, 8), graph.get(0).?.recorded_end.r);
    try std.testing.expectEqual(@as(u64, 5), graph.get(1).?.recorded_end.r);

    const list2 = try lifecycle.list(gpa, &graph, router.active_line);
    defer gpa.free(list2);
    try std.testing.expectEqual(@as(u64, 8), list2[0].recorded_end.r);
    try std.testing.expectEqual(@as(u64, 5), list2[1].recorded_end.r);
}
