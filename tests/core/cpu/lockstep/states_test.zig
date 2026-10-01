//! Covers src/core/cpu/lockstep/states.zig.
const std = @import("std");
const ra8 = @import("ra8");
const states = ra8.core.cpu.lockstep.states;
const snapshot = ra8.core.cpu.lockstep.snapshot;

test "every compared register is printed for both backends" {
    const ours: snapshot.Snapshot = .{ .values = [_]u32{0} ** snapshot.compared.len };
    var buffer: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try states.write(stream.writer(), ours, ours);
    const lines = std.mem.count(u8, stream.getWritten(), "\n");
    try std.testing.expectEqual(snapshot.compared.len + 1, lines);
    try std.testing.expect(std.mem.indexOf(u8, stream.getWritten(), "<-") == null);
}

test "only the registers that differ are marked" {
    const ours: snapshot.Snapshot = .{ .values = [_]u32{0} ** snapshot.compared.len };
    var theirs = ours;
    theirs.values[snapshot.Snapshot.index(.r7).?] = 0x1234;
    var buffer: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try states.write(stream.writer(), ours, theirs);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, stream.getWritten(), "<-"));
    try std.testing.expect(std.mem.indexOf(u8, stream.getWritten(), "  r7         0x00000000 0x00001234  <-\n") != null);
}
