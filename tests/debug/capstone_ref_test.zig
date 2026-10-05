//! Tests for src/debug/capstone_ref.zig.
const std = @import("std");
const ra8 = @import("ra8");
const mod = ra8.core.capstone_ref;

test "the oracle decodes a Thumb store" {
    const text = try mod.one(0x2200_0000, &[_]u8{ 0x01, 0x60 });
    try std.testing.expectEqualStrings("str r1, [r0]", text.slice());
}

test "the linked Capstone reports the version the parity oracle pins" {
    const linked = mod.version();
    try std.testing.expect(linked.major >= 4);
    // This build links Capstone 5; a 4.x or 6.x box skips parity instead.
    if (linked.major != 5) return error.SkipZigTest;
    try std.testing.expectEqual(@as(u32, 0), linked.minor);
}
