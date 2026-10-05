//! Covers src/interfaces/cli/window_main.zig: what `--gui` paces a frame
//! at, and that a build with no window says so instead of running blind.
const std = @import("std");
const ra8 = @import("ra8");
const window_main = ra8.board.window_main;

test "a frame is a sixtieth of a second of core time" {
    try std.testing.expectEqual(@as(u64, 16_666_667), window_main.frame_ns);
}

test "this build has no window to open" {
    try std.testing.expect(window_main.open() == null);
}
