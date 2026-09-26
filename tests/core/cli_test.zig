//! Tests for src/core/cli.zig.
const std = @import("std");
const ra8 = @import("ra8");
const mod = ra8.core.cli;

const parse = mod.parse;
const Part = ra8.core.part.Part;

test "the command line takes an image and an optional instruction budget" {
    const defaults = try parse(&[_][]const u8{ "emu", "a.elf" });
    try std.testing.expectEqualStrings("a.elf", defaults.path);
    try std.testing.expectEqual(@as(usize, 2_000_000), defaults.instructions);

    const bounded = try parse(&[_][]const u8{ "emu", "a.elf", "--instructions", "64" });
    try std.testing.expectEqual(@as(usize, 64), bounded.instructions);

    try std.testing.expectError(error.MissingImage, parse(&[_][]const u8{"emu"}));
    try std.testing.expectError(error.MissingValue, parse(&[_][]const u8{ "emu", "a.elf", "--instructions" }));
    try std.testing.expectError(error.UnknownFlag, parse(&[_][]const u8{ "emu", "a.elf", "--nope" }));
}

test "the part defaults to the RA8D2 and is named, never guessed" {
    const defaults = try parse(&[_][]const u8{ "emu", "a.elf" });
    try std.testing.expectEqual(Part.ra8d2, defaults.part);

    const npu_part = try parse(&[_][]const u8{ "emu", "a.elf", "--part", "ra8p1" });
    try std.testing.expectEqual(Part.ra8p1, npu_part.part);

    try std.testing.expectError(error.UnknownPart, parse(&[_][]const u8{ "emu", "a.elf", "--part", "ra8m1" }));
    try std.testing.expectError(error.MissingValue, parse(&[_][]const u8{ "emu", "a.elf", "--part" }));
}
