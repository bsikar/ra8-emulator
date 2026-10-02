//! Tests for src/interfaces/cli/touch_spec.zig, through the flag that uses it.
const std = @import("std");
const parse = @import("ra8").core.cli.parse;

test "a touch spec is X,Y in panel coordinates" {
    const options = try parse(&[_][]const u8{ "emu", "a.elf", "--touch", "120,48" });
    try std.testing.expectEqual(@as(usize, 1), options.touch_count);
    try std.testing.expectEqual(@as(u16, 120), options.touches[0].x);
    try std.testing.expectEqual(@as(u16, 48), options.touches[0].y);
}

test "a touch spec with no comma or a bad number is refused" {
    try std.testing.expectError(error.BadTouch, parse(&[_][]const u8{ "emu", "a.elf", "--touch", "120" }));
    try std.testing.expectError(error.InvalidCharacter, parse(&[_][]const u8{ "emu", "a.elf", "--touch", "x,4" }));
}
