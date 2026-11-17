//! Operand matches cannot mistake register substrings or writeback for storage.
const std = @import("std");

const operands = @import("ra8").session.annotation_operands;

test "simple memory locations and exact register tokens" {
    try std.testing.expectEqualDeep(operands.Memory{ .reg = 13, .offset = 4 }, operands.memory("ldr r0, [sp, #4]").?);
    try std.testing.expectEqualDeep(operands.Memory{ .reg = 7, .offset = -16 }, operands.memory("str r1, [r7, #-0x10]").?);
    try std.testing.expect(operands.memory("ldr r0, [r7, r1]") == null);
    try std.testing.expect(operands.memory("ldr r0, [r7], #4") == null);
    try std.testing.expect(operands.memory("ldr r0, [r7, #4]!") == null);
    try std.testing.expect(operands.usesRegister("mov r0, r1", 1));
    try std.testing.expect(!operands.usesRegister("mov r0, r12", 1));
    try std.testing.expect(!operands.usesRegister("b #0x100 ; r1", 1));
}
