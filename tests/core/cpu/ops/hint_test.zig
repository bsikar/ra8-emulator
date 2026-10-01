//! Covers src/core/cpu/ops/hint.zig.
const std = @import("std");
const ra8 = @import("ra8");
const hint = ra8.core.cpu.ops.hint;

test "both NOP widths decode" {
    const e = hint.encodings;
    try std.testing.expect(hint.group.decode(.{ .address = 0, .hw1 = e.nop_t1, .size = 2 }) != null);
    try std.testing.expect(hint.group.decode(.{ .address = 0, .hw1 = e.nop_t2_hw1, .hw2 = e.nop_t2_hw2, .size = 4 }) != null);
}

test "the other hints are not claimed yet" {
    // bf10 yield, bf20 wfe, bf30 wfi, bf40 sev, bf08 it eq-shaped
    for ([_]u16{ 0xBF10, 0xBF20, 0xBF30, 0xBF40, 0xBF08 }) |hw1| {
        try std.testing.expect(hint.group.decode(.{ .address = 0, .hw1 = hw1, .size = 2 }) == null);
    }
    // f3af 8001 yield.w
    try std.testing.expect(hint.group.decode(.{ .address = 0, .hw1 = 0xF3AF, .hw2 = 0x8001, .size = 4 }) == null);
}
