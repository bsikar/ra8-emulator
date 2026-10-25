//! Tests for src/session/history/fork_router.zig (Slice 20.2).
const std = @import("std");
const ra8 = @import("ra8");

const fork_router = ra8.session.history_fork_router;
const branch_mod = ra8.session.history_branch;
const position_mod = ra8.session.history_position;
const record_mod = ra8.session.history_record;

const Position = position_mod.Position;
const ForkReason = record_mod.ForkReason;
const BranchGraph = branch_mod.BranchGraph;
const ForkRouter = fork_router.ForkRouter;

test "decide returns live when graph is null" {
    const cursor = Position{ .branch = 0, .r = 5, .phase = .cpu0, .o = 0, .gap = .retired };
    const end = Position{ .branch = 0, .r = 10, .phase = .cpu0, .o = 0, .gap = .retired };
    const decision = fork_router.decide(null, 0, cursor, end, false, .writes);
    try std.testing.expectEqual(fork_router.RouteDecision.live, decision);
}

test "decide returns live when cursor is at or after recorded end" {
    const gpa = std.testing.allocator;
    var graph = try BranchGraph.init(gpa);
    defer graph.deinit();

    var end = graph.get(0).?.recorded_end;
    end.r = 10;
    try graph.insertNode(.{
        .id = 0,
        .parent = 0,
        .fork_at = .{ .branch = 0, .r = 0, .phase = .cpu0, .o = 0, .gap = .retired },
        .reason = .base,
        .recorded_end = end,
    });

    // Equal to recorded end -> live
    const at_end = end;
    try std.testing.expectEqual(fork_router.RouteDecision.live, fork_router.decide(&graph, 0, at_end, end, false, .writes));

    // After recorded end -> live
    var past_end = end;
    past_end.r = 15;
    try std.testing.expectEqual(fork_router.RouteDecision.live, fork_router.decide(&graph, 0, past_end, end, false, .writes));
}

test "decide returns needs_confirmation on first past intervention" {
    const gpa = std.testing.allocator;
    var graph = try BranchGraph.init(gpa);
    defer graph.deinit();

    var end = graph.get(0).?.recorded_end;
    end.r = 10;
    try graph.insertNode(.{
        .id = 0,
        .parent = 0,
        .fork_at = .{ .branch = 0, .r = 0, .phase = .cpu0, .o = 0, .gap = .retired },
        .reason = .base,
        .recorded_end = end,
    });

    const past_cursor = Position{ .branch = 0, .r = 4, .phase = .cpu0, .o = 10, .gap = .polled };
    const decision = fork_router.decide(&graph, 0, past_cursor, end, false, .writes);
    try std.testing.expectEqual(fork_router.RouteDecision.needs_confirmation, decision);
}

test "decide returns fork on past intervention when already confirmed" {
    const gpa = std.testing.allocator;
    var graph = try BranchGraph.init(gpa);
    defer graph.deinit();

    var end = graph.get(0).?.recorded_end;
    end.r = 10;
    try graph.insertNode(.{
        .id = 0,
        .parent = 0,
        .fork_at = .{ .branch = 0, .r = 0, .phase = .cpu0, .o = 0, .gap = .retired },
        .reason = .base,
        .recorded_end = end,
    });

    const past_cursor = Position{ .branch = 0, .r = 4, .phase = .cpu0, .o = 10, .gap = .polled };
    const decision = fork_router.decide(&graph, 0, past_cursor, end, true, .writes);
    try std.testing.expectEqual(fork_router.RouteDecision.fork, decision);
}

test "decide evaluates canonical positions along child branch line" {
    const gpa = std.testing.allocator;
    var graph = try BranchGraph.init(gpa);
    defer graph.deinit();

    // Branch 0 runs to r=10
    var end0 = graph.get(0).?.recorded_end;
    end0.r = 10;
    try graph.insertNode(.{
        .id = 0,
        .parent = 0,
        .fork_at = .{ .branch = 0, .r = 0, .phase = .cpu0, .o = 0, .gap = .retired },
        .reason = .base,
        .recorded_end = end0,
    });

    // Branch 1 forks at r=5
    const fork_pos = Position{ .branch = 0, .r = 5, .phase = .cpu0, .o = 0, .gap = .retired };
    const b1 = try graph.addBranch(0, fork_pos, .writes, 100);
    var b1_node = graph.get(b1).?;
    b1_node.recorded_end = Position{ .branch = b1, .r = 15, .phase = .cpu0, .o = 0, .gap = .retired };
    try graph.insertNode(b1_node);

    // Cursor on branch 0 prefix before fork (r=3) along line 1
    const p_ancestor = Position{ .branch = 0, .r = 3, .phase = .cpu0, .o = 0, .gap = .retired };
    try std.testing.expectEqual(
        fork_router.RouteDecision.needs_confirmation,
        fork_router.decide(&graph, b1, p_ancestor, b1_node.recorded_end, false, .taps),
    );

    // Cursor at exact fork boundary (belongs to child b1)
    const cursor_at_fork = Position{ .branch = b1, .r = 5, .phase = .cpu0, .o = 0, .gap = .retired };
    try std.testing.expectEqual(
        fork_router.RouteDecision.needs_confirmation,
        fork_router.decide(&graph, b1, cursor_at_fork, b1_node.recorded_end, false, .taps),
    );

    // Cursor at tip of branch 1 (r=15) -> live
    try std.testing.expectEqual(
        fork_router.RouteDecision.live,
        fork_router.decide(&graph, b1, b1_node.recorded_end, b1_node.recorded_end, false, .taps),
    );
}

test "ForkRouter state: setPending, dupeAction, nextSeq, and cancel" {
    const gpa = std.testing.allocator;
    var router = ForkRouter.init(gpa, null);
    defer router.deinit();

    try std.testing.expectEqual(@as(u32, 0), router.nextSeq());
    try std.testing.expectEqual(@as(u32, 1), router.nextSeq());
    try std.testing.expect(router.pending_fork == null);

    const mem_bytes = "write-data-to-buffer";
    const pos = Position{ .branch = 0, .r = 2, .phase = .cpu0, .o = 1, .gap = .retired };
    try router.setPending(.writes, pos, .{ .memory = .{ .core = .cpu0, .address = 0x2000_0000, .bytes = mem_bytes } });

    const pending = router.pending_fork orelse return error.TestFailed;
    try std.testing.expectEqual(ForkReason.writes, pending.reason);
    try std.testing.expectEqual(pos.r, pending.position.r);
    try std.testing.expectEqualStrings(mem_bytes, pending.action.memory.bytes);

    router.cancel();
    try std.testing.expect(router.pending_fork == null);
}

test "ForkRouter ownership: 64 KiB memory write, caller buffer overwrite, and leak-free cancel" {
    const gpa = std.testing.allocator;
    var router = ForkRouter.init(gpa, null);
    defer router.deinit();

    // 1. Pending 64 KiB write is duped with no truncation
    var large_write: [65536]u8 = undefined;
    for (&large_write, 0..) |*b, i| b.* = @truncate(i * 3 + 7);
    const pos = Position{ .branch = 0, .r = 1, .phase = .cpu0, .o = 0, .gap = .retired };
    try router.setPending(.writes, pos, .{ .memory = .{ .core = .cpu0, .address = 0x1000, .bytes = &large_write } });

    // Mutate the caller's stack buffer to prove ownership
    @memset(&large_write, 0);

    const popped = router.popPending() orelse return error.TestFailed;
    defer fork_router.freeAction(gpa, @constCast(&popped.action));
    try std.testing.expectEqual(@as(usize, 65536), popped.action.memory.bytes.len);
    for (popped.action.memory.bytes, 0..) |b, i| {
        try std.testing.expectEqual(@as(u8, @truncate(i * 3 + 7)), b);
    }

    // 2. Pending load with buffer overwrite
    var image_buf: [128]u8 = undefined;
    @memcpy(image_buf[0..14], "ORIGINAL-IMAGE");
    try router.setPending(.load, pos, .{ .load = .{ .core = .cpu0, .image = image_buf[0..14] } });
    @memcpy(image_buf[0..14], "MUTATED-IMAGE-");

    const popped_load = router.popPending() orelse return error.TestFailed;
    defer fork_router.freeAction(gpa, @constCast(&popped_load.action));
    try std.testing.expectEqualStrings("ORIGINAL-IMAGE", popped_load.action.load.image);

    // 3. Cancel frees without leaking (std.testing.allocator validates at test exit)
    try router.setPending(.keystrokes, pos, .{ .console = .{ .core = .cpu0, .bytes = "will-be-cancelled" } });
    router.cancel();
    try std.testing.expect(router.pending_fork == null);
}
