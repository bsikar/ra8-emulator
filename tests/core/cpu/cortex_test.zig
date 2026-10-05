//! Covers src/core/cpu/cortex.zig.
const std = @import("std");
const ra8 = @import("ra8");

const Cortex = ra8.core.cpu.cortex.Cortex;

test "the register enum names every register the debugger and report read" {
    try std.testing.expectEqual(@as(usize, 24), @typeInfo(Cortex).@"enum".fields.len);
    try std.testing.expect(@hasField(Cortex, "fpscr"));
    try std.testing.expect(@hasField(Cortex, "psp"));
}
