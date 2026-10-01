//! Covers src/core/cpu/lockstep/report.zig.
const std = @import("std");
const ra8 = @import("ra8");
const report = ra8.core.cpu.lockstep.report;
const run = ra8.core.cpu.lockstep.run;

test "a spent budget is reported as no divergence" {
    var lock: run.Run = .{};
    var buffer: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try report.write(stream.writer(), &lock, .budget);
    try std.testing.expectEqualStrings("lockstep: budget spent, no divergence\n", stream.getWritten());
}

test "a non-encoding stop names its kind and the address" {
    var lock: run.Run = .{ .at = 0x0200_0010 };
    var buffer: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try report.write(stream.writer(), &lock, .{ .stopped = .{ .bus_fault = 0x0200_0010 } });
    try std.testing.expectEqualStrings("lockstep: zig core stopped, bus_fault at 0x02000010\n", stream.getWritten());
}
