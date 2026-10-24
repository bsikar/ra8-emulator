//! Tests for src/interfaces/rpc/session/branch_wire.zig.
const std = @import("std");
const ra8 = @import("ra8");
const wire = ra8.rpc.session.rpc.branch_wire;

test "branch wire types layout and default values" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(wire.BranchItem));

    const item = wire.BranchItem{
        .id = 1,
        .parent = 0,
        .fork_r = 10,
        .recorded_end_r = 20,
        .child_count = 0,
        .reason = 2,
        .flags = 3,
    };

    try std.testing.expectEqual(@as(u32, 1), item.id);
    try std.testing.expectEqual(@as(u32, 0), item.parent);
    try std.testing.expectEqual(@as(u64, 10), item.fork_r);
    try std.testing.expectEqual(@as(u64, 20), item.recorded_end_r);
    try std.testing.expectEqual(@as(u8, 2), item.reason);
    try std.testing.expectEqual(@as(u8, 3), item.flags);
    try std.testing.expectEqual(@as(u16, 0), item.pad);

    const del = wire.BranchDelete{ .branch = 5 };
    try std.testing.expectEqual(@as(u8, 0), del.confirm);

    const conf = wire.BranchConfirmFork{};
    try std.testing.expectEqual(@as(u8, 1), conf.confirm);
}
