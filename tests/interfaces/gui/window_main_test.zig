//! Covers src/interfaces/gui/window_main.zig: what `--gui` paces a frame
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

var fake: ?ra8.gui.headless.Headless = null;

fn fakeOpen() ?ra8.gui.platform.Platform {
    fake = ra8.gui.headless.Headless.init(std.testing.allocator, 320, 200);
    if (fake) |*window| return window.platform();
    return null;
}

fn fakeClose() void {}

test "an opener set by the executable is the window --gui opens" {
    window_main.opener = .{ .open = fakeOpen, .close = fakeClose };
    defer window_main.opener = null;
    const window = window_main.open() orelse return error.NoWindow;
    defer fake.?.deinit();
    try std.testing.expectEqual(@as(u32, 320), window.size().width);
}

fn neverRun(ctx: *anyopaque, pacer: *ra8.board.window_pace.Pacer) u8 {
    _ = pacer;
    const ran: *bool = @ptrCast(@alignCast(ctx));
    ran.* = true;
    return 0;
}

test "with no window the run is never started and --gui says 2" {
    var board = ra8.board.Board.init(std.testing.allocator);
    defer board.deinit();
    var ran = false;
    const code = try window_main.show(std.testing.allocator, .{ .io = std.testing.io, .board = &board, .runner = .{ .ctx = &ran, .run = neverRun } });
    try std.testing.expectEqual(@as(u8, 2), code);
    try std.testing.expect(!ran);
}
