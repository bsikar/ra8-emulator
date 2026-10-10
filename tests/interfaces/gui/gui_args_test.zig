//! Tests for src/interfaces/gui/gui_args.zig: ra8_gui lifts its window flags
//! out of argv and leaves the rest for cli.parse.
const std = @import("std");
const ra8 = @import("ra8");
const gui_args = ra8.board.gui_args;

test "without window flags argv passes through untouched" {
    const taken = try gui_args.take(std.testing.allocator, &.{ "ra8_gui", "a.elf", "--fast" });
    defer std.testing.allocator.free(taken.rest.ptr[0..3]);
    try std.testing.expect(taken.window.stills == null);
    try std.testing.expectEqual(@as(u32, 1), taken.window.stills_every);
    try std.testing.expectEqual(@as(usize, 3), taken.rest.len);
    try std.testing.expectEqualStrings("--fast", taken.rest[2]);
}

test "--window-stills names a directory and how often to keep a frame" {
    const argv: []const []const u8 = &.{ "ra8_gui", "a.elf", "--window-stills", "shots", "--window-stills-every", "30", "--fast" };
    const taken = try gui_args.take(std.testing.allocator, argv);
    defer std.testing.allocator.free(taken.rest.ptr[0..argv.len]);
    try std.testing.expectEqualStrings("shots", taken.window.stills.?);
    try std.testing.expectEqual(@as(u32, 30), taken.window.stills_every);
    try std.testing.expectEqual(@as(usize, 3), taken.rest.len);
    try std.testing.expectEqualStrings("a.elf", taken.rest[1]);
    try std.testing.expectEqualStrings("--fast", taken.rest[2]);
}

test "a missing or zero window flag value is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.BadValue, gui_args.take(a, &.{ "ra8_gui", "a.elf", "--window-stills-every", "0" }));
    try std.testing.expectError(error.BadValue, gui_args.take(a, &.{ "ra8_gui", "a.elf", "--window-stills-every", "x" }));
    try std.testing.expectError(error.MissingValue, gui_args.take(a, &.{ "ra8_gui", "a.elf", "--window-stills" }));
}
