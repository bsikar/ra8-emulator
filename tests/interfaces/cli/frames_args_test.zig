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

test "frame-on-settle captures to its own directory with a virtual stability window" {
    const parsed = try ra8.core.cli.parse(&.{ "emu", "image.elf", "--frame-on-settle", "settled", "--settle-window-ms", "75" });
    try std.testing.expectEqualStrings("settled", parsed.frames.frame_on_settle.?);
    try std.testing.expectEqual(@as(u64, 75_000_000), parsed.frames.settle_window_ns);
}

test "--gui asks for the run to be shown live" {
    const defaults = try cli.parse(&.{ "emu", "a.elf" });
    try std.testing.expect(!defaults.frames.live);
    const asked = try cli.parse(&.{ "emu", "a.elf", "--gui" });
    try std.testing.expect(asked.frames.live);
}

test "--window-stills names a directory and how often to keep a frame" {
    const defaults = try cli.parse(&.{ "emu", "a.elf" });
    try std.testing.expect(defaults.frames.window_stills == null);
    try std.testing.expectEqual(@as(u32, 1), defaults.frames.window_stills_every);
    const asked = try cli.parse(&.{ "emu", "a.elf", "--gui", "--window-stills", "shots", "--window-stills-every", "30" });
    try std.testing.expectEqualStrings("shots", asked.frames.window_stills.?);
    try std.testing.expectEqual(@as(u32, 30), asked.frames.window_stills_every);
    try std.testing.expectError(error.BadValue, cli.parse(&.{ "emu", "a.elf", "--window-stills-every", "0" }));
    try std.testing.expectError(error.MissingValue, cli.parse(&.{ "emu", "a.elf", "--window-stills" }));
}
