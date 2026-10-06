//! A read of a host handle that never holds up the run (RA8EMU-725).
//!
//! Host stdin under `--console` and the `--touch @PATH` source are polled at
//! board boundaries, so a read with nothing waiting has to come back at once.
//! On POSIX that is poll() with a zero timeout ahead of the read. Windows has
//! no poll() for pipes or files, so there the handle goes through the camera
//! pipe's reader (pipe_windows.zig): PeekNamedPipe for a pipe, and a plain
//! read for a file, which never waits. An interactive Windows console is
//! neither, and goes through host_console.zig (RA8EMU-723).
const std = @import("std");
const builtin = @import("builtin");
const pipe_windows = @import("camera/pipe_windows.zig");
const host_console = @import("host_console.zig");

pub const Handle = std.posix.fd_t;
const is_windows = builtin.os.tag == .windows;

/// Standard input's handle, asked for at run time: on Windows it is a
/// HANDLE the process inherits, not descriptor 0.
pub fn stdin() Handle {
    return std.io.getStdIn().handle;
}

/// Open PATH, a file or a FIFO, for reading. On POSIX the open does not
/// block, so a FIFO with no writer yet does not hold up the run.
pub fn open(path: []const u8) !Handle {
    if (is_windows) return (try std.fs.cwd().openFile(path, .{})).handle;
    return std.posix.open(path, .{ .NONBLOCK = true }, 0);
}

/// Read what is waiting on `handle` into `into`. Null means nothing is
/// waiting (or the read failed) and the caller asks again next boundary;
/// 0 means end of input; anything else is the count read.
pub fn read(handle: Handle, into: []u8) ?usize {
    if (is_windows) {
        if (host_console.isConsole(handle)) return host_console.read(handle, into);
        return pipe_windows.readNow(handle, true, into) catch null;
    }
    var fds = [_]std.posix.pollfd{
        .{ .fd = handle, .events = std.posix.POLL.IN, .revents = 0 },
    };
    const ready = std.posix.poll(&fds, 0) catch return null;
    // A pipe whose writer has gone reports HUP, not IN; the read then
    // returns 0 so the caller can stop polling.
    const wake = std.posix.POLL.IN | std.posix.POLL.HUP;
    if (ready == 0 or fds[0].revents & wake == 0) return null;
    return std.posix.read(handle, into) catch null;
}
