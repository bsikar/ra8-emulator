//! Tests for src/core/disasm.zig.
const std = @import("std");
const ra8 = @import("ra8");
const mod = ra8.core.disasm;

const Error = mod.Error;
const one = mod.one;
test "a Thumb store decodes to its mnemonic and operands" {
    const text = try one(0x2200_0000, &[_]u8{ 0x01, 0x60 });
    try std.testing.expectEqualStrings("str r1, [r0]", text.slice());
}

test "bytes that decode to nothing are an error, not a guess" {
    try std.testing.expectError(Error.NothingDecoded, one(0x2200_0000, &[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF }));
}
