//! Tests for src/interfaces/rpc/session/branch_wire.zig.
const std = @import("std");
const ra8 = @import("ra8");
const wire = ra8.rpc.session.rpc.branch_wire;

test "a branch item round trips through its wire bytes, even from an unaligned buffer" {
    try std.testing.expectEqual(@as(usize, 30), wire.item_bytes);

    const item = wire.BranchItem{
        .id = 0x01020304,
        .parent = 7,
        .fork_r = 0x1122334455667788,
        .recorded_end_r = 20,
        .child_count = 3,
        .reason = 2,
        .flags = 5,
    };

    // One spare byte in front puts the items at an odd address, which is
    // what a frame's payload slice looks like on the wire.
    var storage: [1 + 2 * wire.item_bytes]u8 = undefined;
    const bytes = storage[1..];
    wire.put(bytes, 0, item);
    wire.put(bytes, 1, .{ .id = 9, .parent = 1, .fork_r = 1, .recorded_end_r = 2, .child_count = 0, .reason = 8, .flags = 0 });

    try std.testing.expectEqual(@as(usize, 2), wire.count(bytes));
    try std.testing.expectEqual(item, wire.get(bytes, 0));
    try std.testing.expectEqual(@as(u32, 9), wire.get(bytes, 1).id);
    try std.testing.expectEqual(@as(u8, 8), wire.get(bytes, 1).reason);
    // Little-endian on the wire whatever the host.
    try std.testing.expectEqual(@as(u8, 0x04), bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x88), bytes[8]);

    const del = wire.BranchDelete{ .branch = 5 };
    try std.testing.expectEqual(@as(u8, 0), del.confirm);

    const conf = wire.BranchConfirmFork{};
    try std.testing.expectEqual(@as(u8, 1), conf.confirm);
}
