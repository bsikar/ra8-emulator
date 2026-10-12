//! Anonymous byte pipes for host transports and their test fixtures.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("win32.zig");

pub const Options = struct { nonblocking: bool = false };

/// Returns the read end followed by the write end; close both with read.close.
/// POSIX can mark the handles nonblocking. Windows callers poll through
/// read.read or a transport's readiness check before reading the pipe.
pub fn create(options: Options) ![2]std.posix.fd_t {
    if (builtin.os.tag != .windows) return std.Io.Threaded.pipe2(.{ .NONBLOCK = options.nonblocking });
    var ends: [2]std.posix.fd_t = undefined;
    if (!win32.CreatePipe(&ends[0], &ends[1], null, 0).toBool()) return error.PipeFailed;
    return ends;
}
