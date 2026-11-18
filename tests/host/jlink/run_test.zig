const builtin = @import("builtin");
const std = @import("std");

const host = @import("ra8").host;

test "bounded probe runner captures output and enforces timeout" {
    if (!host.build.process.supported) return error.SkipZigTest;
    const on_windows = builtin.os.tag == .windows;
    const fast: []const []const u8 = if (on_windows)
        &.{ "cmd.exe", "/d", "/c", "echo probe-ok" }
    else
        &.{ "/bin/sh", "-c", "printf probe-ok" };
    var out: [256]u8 = undefined;
    const ran = try host.jlink.run.run(std.testing.io, fast, &out, 5_000);
    try std.testing.expectEqual(@as(i32, 0), ran.code);
    try std.testing.expect(std.mem.indexOf(u8, ran.output, "probe-ok") != null);

    const slow: []const []const u8 = if (on_windows)
        &.{ "cmd.exe", "/d", "/c", "ping -n 30 127.0.0.1 >NUL" }
    else
        &.{ "/bin/sh", "-c", "sleep 30" };
    try std.testing.expectError(error.ProbeTimeout, host.jlink.run.run(std.testing.io, slow, &out, 40));
}
