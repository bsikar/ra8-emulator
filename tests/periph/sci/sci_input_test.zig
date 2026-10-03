//! Covers host input delivery to the console channel's receive register.
const std = @import("std");
const ra8 = @import("ra8");
const sci = ra8.periph.sci;
const input = ra8.core.cli.console_input;

test "host input waiting on stdin reaches console SCI receive" {
    const fds = try std.posix.pipe();
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

    try std.testing.expectEqual(@as(usize, 2), try std.posix.write(fds[1], "hi"));
    var unit = sci.Sci.init();
    unit.write(sci.regAddress(sci.console_channel, sci.off_ccr0), 4, sci.ccr0.te | sci.ccr0.re);
    var reader: input.Input = .{ .enabled = true, .fd = fds[0] };
    reader.poll(&unit);

    const rdr = sci.regAddress(sci.console_channel, sci.off_rdr);
    try std.testing.expectEqual(@as(u32, 'h'), unit.read(rdr, 4));
    try std.testing.expectEqual(@as(u32, 'i'), unit.read(rdr, 4));
    try std.testing.expectEqual(@as(u32, 2), unit.console().received);
}
