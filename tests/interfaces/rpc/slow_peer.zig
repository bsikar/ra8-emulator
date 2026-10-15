//! A loopback gdb client that stops reading, for the tests that drop a slow
//! peer (RA8EMU-727). Its receive buffer is small before connect: a window
//! already advertised does not shrink, so a Darwin peer shrunk after
//! connect goes on taking bytes long after the test stops reading.
const std = @import("std");
const builtin = @import("builtin");
const ready = @import("ra8").host.sock.ready;
const io = std.testing.io;

/// The receive buffer, in bytes, the client connects with.
const small: c_int = 4096;
/// Timed-out sends in a row that count as a settled block: a Linux receiver
/// collapsing its queue reopens the window after the first few.
const settled = 10;

/// A stream to loopback `port` whose receive window is small from the start.
pub fn connect(port: u16) !std.Io.net.Stream {
    const address = std.Io.net.IpAddress{ .ip4 = .loopback(port) };
    if (builtin.os.tag == .windows) return address.connect(io, .{ .mode = .stream });
    const posix = std.posix;
    const fd = std.c.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    if (fd < 0) return error.SystemResources;
    errdefer _ = std.c.close(fd);
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVBUF, std.mem.asBytes(&small));
    const in: posix.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = @bitCast(address.ip4.bytes) };
    if (std.c.connect(fd, @ptrCast(&in), @sizeOf(posix.sockaddr.in)) != 0) return error.ConnectionRefused;
    return .{ .socket = .{ .handle = fd, .address = address } };
}

/// Fill the host's `stream` to the peer until even one byte stays queued,
/// so the host's next reply meets backpressure. The host keeps its own send
/// buffer: a shrunk one on Darwin goes on draining a byte at a time.
pub fn block(stream: std.Io.net.Stream) !void {
    const bytes: [64 * 1024]u8 = @splat('g');
    var chunk: []const u8 = &bytes;
    var still: usize = 0;
    const deadline = std.Io.Timestamp.now(io, .awake).toMilliseconds() + 5000;
    while (std.Io.Timestamp.now(io, .awake).toMilliseconds() < deadline) {
        ready.sendAll(io, stream.socket.handle, chunk, 20) catch |err| {
            try std.testing.expectEqual(error.Timeout, err);
            chunk = "g";
            still += 1;
            if (still == settled) return;
            continue;
        };
        still = 0;
    }
    return error.Timeout;
}
