//! Tests for src/interfaces/cli/frame_out.zig.
const std = @import("std");
const ra8 = @import("ra8");
const frame_out = ra8.board.report.frame_out;
const cli = ra8.core.cli;

test "a saved frame goes out opaque whatever alpha the mixer left" {
    const pixels = [_]u32{ 0x0012_3456, 0x80AB_CDEF };
    var rgba: [8]u8 = undefined;
    try frame_out.opaqueRgba(&pixels, &rgba);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x12, 0x34, 0x56, 0xFF, 0xAB, 0xCD, 0xEF, 0xFF }, &rgba);
}

test "--frame-out takes a path and is off by default" {
    try std.testing.expectEqual(@as(?[]const u8, null), (try cli.parse(&[_][]const u8{ "emu", "a.elf" })).frame_out);
    const given = try cli.parse(&[_][]const u8{ "emu", "a.elf", "--frame-out", "panel.png" });
    try std.testing.expectEqualStrings("panel.png", given.frame_out.?);
    try std.testing.expectError(error.MissingValue, cli.parse(&[_][]const u8{ "emu", "a.elf", "--frame-out" }));
}

test "no path means no line and no file" {
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();
    try frame_out.report(buffer.writer(), undefined, null);
    try std.testing.expectEqual(@as(usize, 0), buffer.items.len);
}

test "a run with no panel frame still writes the board view with its LEDs" {
    var board = ra8.board.Board.init(std.testing.allocator);
    defer board.deinit();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "view.png" });
    defer std.testing.allocator.free(path);
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();
    try frame_out.report(buffer.writer(), &board, path);
    try std.testing.expect(std.mem.startsWith(u8, buffer.items, "frame-out: no panel frame, the LEDs on a 1056x664 board view"));
    var magic: [8]u8 = undefined;
    _ = try (try dir.dir.openFile("view.png", .{})).readAll(&magic);
    try std.testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", &magic);
}

test {
    _ = @import("board_view_test.zig");
}
