//! Covers the host-independent parts of src/periph/camera/pipe_windows.zig:
//! how a Win32 read error maps to the capture's next step, and how a pipe
//! argument becomes a `\\.\pipe\` name. The server itself needs Windows.
const std = @import("std");
const ra8 = @import("ra8");

const win = ra8.periph.ceu.camera.pipe.pipe_windows;
const Win32Error = std.os.windows.Win32Error;

test "an empty nowait pipe would block, a listening one waits for its writer" {
    try std.testing.expectEqual(win.Outcome.would_block, win.outcome(Win32Error.NO_DATA));
    try std.testing.expectEqual(win.Outcome.listening, win.outcome(Win32Error.PIPE_LISTENING));
}

test "a writer that hung up closes the source and other errors fail" {
    try std.testing.expectEqual(win.Outcome.closed, win.outcome(Win32Error.BROKEN_PIPE));
    try std.testing.expectEqual(win.Outcome.closed, win.outcome(Win32Error.PIPE_NOT_CONNECTED));
    try std.testing.expectEqual(win.Outcome.failed, win.outcome(Win32Error.ACCESS_DENIED));
}

test "a bare name gains the pipe prefix" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\\\\.\\pipe\\ra8cam", try win.fullName(&buf, "ra8cam"));
}

test "a full pipe path is kept as given, in any case" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\\\\.\\PIPE\\cam", try win.fullName(&buf, "\\\\.\\PIPE\\cam"));
}

test "a file path, an empty name or a bare prefix is not a pipe" {
    var buf: [64]u8 = undefined;
    try std.testing.expectError(error.NotAPipe, win.fullName(&buf, "C:\\cam.raw"));
    try std.testing.expectError(error.NotAPipe, win.fullName(&buf, "dir/cam"));
    try std.testing.expectError(error.NotAPipe, win.fullName(&buf, ""));
    try std.testing.expectError(error.NotAPipe, win.fullName(&buf, "\\\\.\\pipe\\"));
}

test "a name longer than the buffer is refused" {
    var buf: [12]u8 = undefined;
    try std.testing.expectError(error.NameTooLong, win.fullName(&buf, "a_long_pipe_name"));
}
