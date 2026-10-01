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

test "a divergence prints both register states after the mismatch" {
    var lock: run.Run = .{};
    const zero: ra8.core.cpu.lockstep.snapshot.Snapshot = .{ .values = [_]u32{0} ** ra8.core.cpu.lockstep.snapshot.compared.len };
    var theirs = zero;
    theirs.values[0] = 1;
    const found: ra8.core.cpu.lockstep.step.Divergence = .{
        .class = "hint",
        .instr = .{ .address = 0x0200_0000, .hw1 = 0xbf00, .size = 2 },
        .what = .{ .register = .{ .name = .r0, .ours = 0, .oracle = 1 } },
        .ours = zero,
        .oracle = theirs,
    };
    var buffer: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try report.write(stream.writer(), &lock, .{ .diverged = found });
    try std.testing.expect(std.mem.indexOf(u8, stream.getWritten(), "register   zig        unicorn\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, stream.getWritten(), "  r0         0x00000000 0x00000001  <-\n") != null);
}
