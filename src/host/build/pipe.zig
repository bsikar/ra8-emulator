//! Read one available compiler-output chunk without blocking the control loop.
const std = @import("std");
const windows = @import("../win32.zig");
pub fn read(io: std.Io, file: std.Io.File, bytes: []u8) !?usize {
    var count = bytes.len;
    if (@import("builtin").os.tag == .windows) {
        var available: u32 = 0;
        if (!windows.PeekNamedPipe(file.handle, null, 0, null, &available, null).toBool()) {
            return switch (std.os.windows.GetLastError()) {
                .BROKEN_PIPE, .PIPE_NOT_CONNECTED => 0,
                else => error.OutputReadFailed,
            };
        }
        if (available == 0) return null;
        count = @min(count, available);
    } else {
        var descriptors = [_]std.posix.pollfd{.{ .fd = file.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&descriptors, 0) == 0) return null;
        if (descriptors[0].revents & (std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0) return error.OutputReadFailed;
    }
    var slices = [_][]u8{bytes[0..count]};
    return file.readStreaming(io, &slices) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => return err,
    };
}
