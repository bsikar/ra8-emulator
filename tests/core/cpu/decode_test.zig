//! Covers src/core/cpu/decode.zig.
const std = @import("std");
const ra8 = @import("ra8");
const decode = ra8.core.cpu.decode;

test "a known encoding comes back with its class" {
    const hit = decode.decode(.{ .address = 0, .hw1 = 0xBF00, .size = 2 }).?;
    try std.testing.expectEqualStrings("hint", hit.group);
    try std.testing.expect(hit.oracle);
}

test "an encoding no group claims is refused" {
    // de00  udf #0, permanently undefined
    try std.testing.expect(decode.decode(.{ .address = 0, .hw1 = 0xDE00, .size = 2 }) == null);
    // f7f0 a000  udf.w #0
    try std.testing.expect(decode.decode(.{ .address = 0, .hw1 = 0xF7F0, .hw2 = 0xA000, .size = 4 }) == null);
}
