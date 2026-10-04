//! Tests for CLI frame capture arguments in src/interfaces/cli/frames_args.zig.
const std = @import("std");
const ra8 = @import("ra8");
const cli = ra8.core.cli;

test "frame sequence flags are optional and validate the scan interval" {
    const defaults = try cli.parse(&.{ "emu", "a.elf" });
    try std.testing.expect(defaults.frames.frames_out == null);
    try std.testing.expect(defaults.frames.gif_out == null);
    try std.testing.expectEqual(@as(usize, 1), defaults.frames.frames_every);

    const asked = try cli.parse(&.{ "emu", "a.elf", "--frames-out", "frames", "--gif-out", "movie.gif", "--frames-every", "2" });
    try std.testing.expectEqualStrings("frames", asked.frames.frames_out.?);
    try std.testing.expectEqualStrings("movie.gif", asked.frames.gif_out.?);
    try std.testing.expectEqual(@as(usize, 2), asked.frames.frames_every);
    try std.testing.expectError(error.BadValue, cli.parse(&.{ "emu", "a.elf", "--frames-every", "0" }));
    try std.testing.expectError(error.MissingValue, cli.parse(&.{ "emu", "a.elf", "--frames-out" }));
    try std.testing.expectError(error.MissingValue, cli.parse(&.{ "emu", "a.elf", "--gif-out" }));
}
