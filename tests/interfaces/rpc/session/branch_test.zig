//! Tests for src/interfaces/rpc/session/branch.zig (Slice 20.4 RPC methods).
const std = @import("std");
const ra8 = @import("ra8");

const branch_rpc = ra8.rpc.session.branch;
const proto = ra8.rpc.session.rpc;
const Rig = @import("advance_rig.zig").Rig;
const branch_mod = ra8.session.history_branch;
const fork_router_mod = ra8.session.history_fork_router;
const Position = ra8.session.history_position.Position;

fn pos(b: u32, r: u64) Position {
    return .{ .branch = b, .r = r, .phase = .cpu0, .o = 0, .gap = .retired };
}

test "branchList returns branch array over RPC context" {
    var rig = Rig{};
    try rig.open();
    defer rig.close();

    var scratch: [8192]u8 = undefined;
    rig.context.scratch = &scratch;
    rig.context.gpa = std.testing.allocator;

    const gpa = std.testing.allocator;
    var graph = try branch_mod.BranchGraph.init(gpa);
    defer graph.deinit();

    var n0 = graph.get(0).?;
    n0.recorded_end = pos(0, 100);
    try graph.insertNode(n0);

    try graph.insertNode(.{
        .id = 1,
        .parent = 0,
        .fork_at = pos(0, 40),
        .reason = .writes,
        .recorded_end = pos(1, 80),
    });

    var router = fork_router_mod.ForkRouter.init(gpa, &graph);
    defer router.deinit();
    rig.session.fork_router = &router;

    const outcome = branch_rpc.branchList(&rig.context, .{ .core = .cpu0 });
    switch (outcome) {
        .ok => |list| {
            const items = std.mem.bytesAsSlice(proto.BranchItem, list.bytes);
            try std.testing.expectEqual(@as(u32, 2), list.count);
            try std.testing.expectEqual(@as(usize, 2), items.len);
            try std.testing.expectEqual(@as(u32, 0), items[0].id);
            try std.testing.expectEqual(@as(u32, 1), items[0].child_count);
            try std.testing.expectEqual(@as(u32, 1), items[1].id);
            try std.testing.expectEqual(@as(u64, 40), items[1].fork_r);
            try std.testing.expectEqual(@as(u64, 80), items[1].recorded_end_r);
        },
        .err => return error.UnexpectedRpcError,
    }
}

test "branchSwitch and branchDelete handle confirmation, protection and active line updates" {
    var rig = Rig{};
    try rig.open();
    defer rig.close();

    var scratch: [8192]u8 = undefined;
    rig.context.scratch = &scratch;
    rig.context.gpa = std.testing.allocator;

    const gpa = std.testing.allocator;
    var graph = try branch_mod.BranchGraph.init(gpa);
    defer graph.deinit();

    var n0 = graph.get(0).?;
    n0.recorded_end = pos(0, 100);
    try graph.insertNode(n0);

    try graph.insertNode(.{
        .id = 1,
        .parent = 0,
        .fork_at = pos(0, 50),
        .reason = .writes,
        .recorded_end = pos(1, 80),
    });

    var router = fork_router_mod.ForkRouter.init(gpa, &graph);
    defer router.deinit();
    rig.session.fork_router = &router;

    // Switch to branch 1
    const sw_outcome = branch_rpc.branchSwitch(&rig.context, .{ .branch = 1 });
    try std.testing.expect(sw_outcome == .ok);
    try std.testing.expectEqual(@as(u32, 1), router.active_line);

    // Try deleting branch 1 without confirmation -> refused
    const del_noconfirm = branch_rpc.branchDelete(&rig.context, .{ .branch = 1, .confirm = 0 });
    try std.testing.expect(del_noconfirm == .err);

    // Try deleting active branch 1 -> refused
    const del_active = branch_rpc.branchDelete(&rig.context, .{ .branch = 1, .confirm = 1 });
    try std.testing.expect(del_active == .err);

    // Switch back to branch 0
    _ = branch_rpc.branchSwitch(&rig.context, .{ .branch = 0 });
    try std.testing.expectEqual(@as(u32, 0), router.active_line);

    // Now delete branch 1 with confirm
    const del_ok = branch_rpc.branchDelete(&rig.context, .{ .branch = 1, .confirm = 1 });
    try std.testing.expect(del_ok == .ok);
    try std.testing.expect(graph.get(1) == null);
}

test "branchConfirmFork, branchCancelFork and branchStatus reflect pending fork lifecycle" {
    var rig = Rig{};
    try rig.open();
    defer rig.close();

    const gpa = std.testing.allocator;
    var graph = try branch_mod.BranchGraph.init(gpa);
    defer graph.deinit();

    var router = fork_router_mod.ForkRouter.init(gpa, &graph);
    defer router.deinit();
    rig.session.fork_router = &router;

    // Initially no pending fork
    const st0 = branch_rpc.branchStatus(&rig.context, .{ .core = .cpu0 });
    try std.testing.expectEqual(@as(u8, 0), st0.ok.pending);

    // Inject a pending fork
    try router.setPending(.writes, pos(0, 25), .{ .memory = .{ .core = .cpu0, .address = 0x100, .bytes = "data" } });

    // Status now reports pending fork
    const st1 = branch_rpc.branchStatus(&rig.context, .{ .core = .cpu0 });
    try std.testing.expectEqual(@as(u8, 1), st1.ok.pending);
    try std.testing.expectEqual(@as(u64, 25), st1.ok.r);

    // Cancel fork
    const cancel_res = branch_rpc.branchCancelFork(&rig.context, .{});
    try std.testing.expect(cancel_res == .ok);

    const st2 = branch_rpc.branchStatus(&rig.context, .{ .core = .cpu0 });
    try std.testing.expectEqual(@as(u8, 0), st2.ok.pending);
}
