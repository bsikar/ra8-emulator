//! Covers host input delivery to the console channel's receive register.
const std = @import("std");
const ra8 = @import("ra8");
const sci = ra8.periph.sci;
const input = ra8.core.cli.console_input;

/// Writes all of `bytes` to a pipe end, as the host side of the test.
fn send(fd: std.posix.fd_t, bytes: []const u8) !void {
    const end: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    try end.writeStreamingAll(std.testing.io, bytes);
}

test "host input waiting on stdin reaches console SCI receive" {
    const fds = try std.Io.Threaded.pipe2(.{});
    defer std.Io.Threaded.closeFd(fds[0]);
    defer std.Io.Threaded.closeFd(fds[1]);

    try send(fds[1], "hi");
    var unit = sci.Sci.init();
    unit.write(sci.regAddress(sci.console_channel, sci.off_ccr0), 4, sci.ccr0.te | sci.ccr0.re);
    var reader: input.Input = .{ .enabled = true, .fd = fds[0] };
    reader.poll(&unit);

    const rdr = sci.regAddress(sci.console_channel, sci.off_rdr);
    try std.testing.expectEqual(@as(u32, 'h'), unit.read(rdr, 4));
    try std.testing.expectEqual(@as(u32, 'i'), unit.read(rdr, 4));
    try std.testing.expectEqual(@as(u32, 2), unit.console().received);
}
