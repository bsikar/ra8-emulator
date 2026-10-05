//! Covers src/interfaces/cli/state_args.zig: `--save-state` and
//! `--load-state` (RA8EMU-696).
const std = @import("std");
const ra8 = @import("ra8");

const state_args = ra8.board.zig_run.state_args;

test "both flags take a path and leave the index on it" {
    var options: state_args.Options = .{};
    const argv = [_][]const u8{ "--save-state", "a.state", "--load-state", "b.state" };
    var index: usize = 0;
    try std.testing.expect(try state_args.parse(&options, &argv, &index));
    try std.testing.expectEqual(@as(usize, 1), index);
    index = 2;
    try std.testing.expect(try state_args.parse(&options, &argv, &index));
    try std.testing.expectEqualStrings("a.state", options.save.?);
    try std.testing.expectEqualStrings("b.state", options.load.?);
    try std.testing.expect(options.wanted());
}

test "a flag with no path is said plainly" {
    var options: state_args.Options = .{};
    const argv = [_][]const u8{"--load-state"};
    var index: usize = 0;
    try std.testing.expectError(error.MissingValue, state_args.parse(&options, &argv, &index));
}

test "other flags are left for the next parser" {
    var options: state_args.Options = .{};
    const argv = [_][]const u8{"--frames-out"};
    var index: usize = 0;
    try std.testing.expect(!try state_args.parse(&options, &argv, &index));
    try std.testing.expect(!options.wanted());
}
