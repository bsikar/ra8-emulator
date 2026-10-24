//! Branch RPC handlers (Slice 20.4): list, switch, delete, confirm and cancel fork.
const std = @import("std");
const rpc = @import("ra8_rpc_wire");
const proto = @import("rpc.zig");
const handlers = @import("handlers.zig");
const ra8_session = @import("ra8_session");
const lifecycle = ra8_session.history_lifecycle;

const AckOutcome = rpc.Outcome(proto.Ack);
const ListOutcome = rpc.Outcome(proto.BranchList);
const StatusOutcome = rpc.Outcome(proto.ForkStatus);

fn refuse() AckOutcome {
    return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.refused)) };
}

pub fn branchList(context: *handlers.Context, args: proto.CoreOnly) ListOutcome {
    _ = args;
    const gpa = context.gpa orelse return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.refused)) };
    const router = context.session.fork_router orelse return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.history)) };
    const graph = router.graph orelse return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.history)) };
    const info = lifecycle.list(gpa, graph, router.active_line) catch return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.refused)) };
    defer gpa.free(info);

    const items_ptr: [*]proto.BranchItem = @ptrCast(@alignCast(context.scratch.ptr));
    const max_items = @min(context.scratch.len / @sizeOf(proto.BranchItem), proto.BranchList.max_len.bytes / @sizeOf(proto.BranchItem));
    const count = @min(info.len, max_items);
    const out_items = items_ptr[0..count];

    for (info[0..count], 0..) |item, i| {
        var flags: u8 = 0;
        if (item.is_live) flags |= 1;
        if (item.is_kept) flags |= 2;
        if (item.is_pinned) flags |= 4;
        out_items[i] = .{
            .id = item.id,
            .parent = item.parent,
            .fork_r = item.fork_at.r,
            .recorded_end_r = item.recorded_end.r,
            .child_count = item.child_count,
            .reason = @backingInt(item.reason),
            .flags = flags,
            .pad = 0,
        };
    }
    return .{ .ok = .{ .count = @intCast(count), .bytes = std.mem.sliceAsBytes(out_items) } };
}

pub fn branchSwitch(context: *handlers.Context, args: proto.BranchSwitch) AckOutcome {
    lifecycle.switchBranch(context.session, context.transport, args.branch) catch |err| switch (err) {
        error.NoHistory => return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.history)) },
        else => return refuse(),
    };
    return .{ .ok = .{ .accepted = 1 } };
}

pub fn branchDelete(context: *handlers.Context, args: proto.BranchDelete) AckOutcome {
    _ = lifecycle.removeBranch(context.session, args.branch, args.confirm != 0) catch |err| switch (err) {
        error.NoHistory => return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.history)) },
        else => return refuse(),
    };
    return .{ .ok = .{ .accepted = 1 } };
}

pub fn branchConfirmFork(context: *handlers.Context, args: proto.BranchConfirmFork) AckOutcome {
    _ = args;
    context.session.confirmFork() catch return refuse();
    return .{ .ok = .{ .accepted = 1 } };
}

pub fn branchCancelFork(context: *handlers.Context, args: proto.BranchCancelFork) AckOutcome {
    _ = args;
    context.session.cancelFork();
    return .{ .ok = .{ .accepted = 1 } };
}

pub fn branchStatus(context: *handlers.Context, args: proto.CoreOnly) StatusOutcome {
    _ = args;
    if (context.session.forkPending()) |pending| {
        return .{
            .ok = .{
                .pending = 1,
                .reason = @backingInt(pending.reason),
                .branch = pending.position.branch,
                .r = pending.position.r,
            },
        };
    }
    return .{
        .ok = .{
            .pending = 0,
            .reason = 0,
            .branch = 0,
            .r = 0,
        },
    };
}
