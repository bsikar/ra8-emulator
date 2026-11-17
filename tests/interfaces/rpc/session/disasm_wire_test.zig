//! The debugger extension retains a stable bounded wire request.
const std = @import("std");

const proto = @import("ra8").rpc.session.rpc;
const workspace_wire = @import("ra8").rpc.workspace_wire;

test "disassembly request bytes and method identifier are stable" {
    var buffer: [64]u8 = undefined;
    const encoded = try proto.encode(proto.Disassemble, .{ .core = .cpu0, .address = 0x100, .count = 4 }, &buffer);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 1, 0, 0, 4, 0 }, encoded);
    try std.testing.expectEqual(@as(u16, 0x01A0), @backingInt(proto.Method.disassemble));
    try std.testing.expect(@backingInt(proto.Method.disassemble) != @backingInt(workspace_wire.Method.list));
    try std.testing.expectError(error.Truncated, proto.decode(proto.Disassemble, encoded[0..6]));
}
