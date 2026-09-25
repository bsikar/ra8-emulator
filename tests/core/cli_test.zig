//! Tests for src/core/cli.zig.
const std = @import("std");
const ra8 = @import("ra8");
const mod = ra8.core.cli;

const parse = mod.parse;

test "the command line takes an image and an optional instruction budget" {
    const defaults = try parse(&[_][]const u8{ "emu", "a.elf" });
    try std.testing.expectEqualStrings("a.elf", defaults.path);
    try std.testing.expectEqual(@as(usize, 2_000_000), defaults.instructions);

    const bounded = try parse(&[_][]const u8{ "emu", "a.elf", "--instructions", "64" });
    try std.testing.expectEqual(@as(usize, 64), bounded.instructions);

    try std.testing.expectError(error.MissingImage, parse(&[_][]const u8{"emu"}));
    try std.testing.expectError(error.UnknownFlag, parse(&[_][]const u8{ "emu", "a.elf", "--nope" }));
}
