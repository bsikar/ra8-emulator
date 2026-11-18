//! Covers src/interfaces/rpc/session/cores_wire.zig: round-trip encoding of
//! per-core topology items (RA8EMU-1342).
const ra8 = @import("ra8");
const std = @import("std");

const wire = ra8.rpc.session.cores_wire;

test "CoreItem round-trips slot, cpuid, capability flags, fpu, systicks and name" {
    var bytes: [wire.max_items * wire.item_bytes]u8 = undefined;
    var first: wire.CoreItem = .{
        .slot = 0,
        .attached = 1,
        .cpuid = 0x410F_D232,
        .flags = wire.flags.v8_1m | wire.flags.mve | wire.flags.lob | wire.flags.security,
        .fpu = 2,
        .systicks = 2,
        .name_len = 10,
    };
    @memcpy(first.name[0..10], "Cortex-M85");
    var second: wire.CoreItem = .{
        .slot = 1,
        .attached = 0,
        .cpuid = 0x410F_D214,
        .flags = wire.flags.security,
        .fpu = 1,
        .systicks = 2,
        .name_len = 10,
    };
    @memcpy(second.name[0..10], "Cortex-M33");
    wire.put(&bytes, 0, first);
    wire.put(&bytes, 1, second);
    try std.testing.expectEqual(@as(usize, 2), wire.count(&bytes));
    const got0 = wire.get(&bytes, 0);
    const got1 = wire.get(&bytes, 1);
    try std.testing.expectEqual(@as(u8, 0), got0.slot);
    try std.testing.expectEqual(@as(u8, 1), got0.attached);
    try std.testing.expectEqual(@as(u32, 0x410F_D232), got0.cpuid);
    try std.testing.expectEqual(first.flags, got0.flags);
    try std.testing.expectEqualStrings("Cortex-M85", got0.nameSlice());
    try std.testing.expectEqual(@as(u8, 1), got1.slot);
    try std.testing.expectEqual(@as(u8, 0), got1.attached);
    try std.testing.expectEqual(@as(u32, 0x410F_D214), got1.cpuid);
    try std.testing.expectEqualStrings("Cortex-M33", got1.nameSlice());
}
