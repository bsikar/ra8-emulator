//! Wire stability and row packing tests for disassembly RPC requests and packed replies.
const std = @import("std");

const ra8 = @import("ra8");

const disasm_wire = ra8.rpc.session.disasm_wire;
const proto = ra8.rpc.session.rpc;
const workspace_wire = ra8.rpc.workspace_wire;

test "disassembly request bytes and method identifier are stable" {
    var buffer: [64]u8 = undefined;
    const encoded = try proto.encode(proto.Disassemble, .{ .core = .cpu0, .address = 0x100, .count = 4 }, &buffer);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 1, 0, 0, 4, 0 }, encoded);
    try std.testing.expectEqual(@as(u16, 0x01A0), @backingInt(proto.Method.disassemble));
    try std.testing.expect(@backingInt(proto.Method.disassemble) != @backingInt(workspace_wire.Method.list));
    try std.testing.expectError(error.Truncated, proto.decode(proto.Disassemble, encoded[0..6]));
}

test "DisasmRow packing and Reader round-trip" {
    var buf: [512]u8 = undefined;
    var at: usize = 0;

    const r1: proto.DisasmRow = .{
        .address = 0x0200_0008,
        .size = 2,
        .decoded = 1,
        .raw = .{ 0x10, 0xb5, 0x00, 0x00 },
        .text = "push {r4, lr}",
        .symbol = "Reset_Handler",
    };
    const r2: proto.DisasmRow = .{
        .address = 0x0200_000a,
        .size = 4,
        .decoded = 1,
        .raw = .{ 0x00, 0xf0, 0x20, 0xf8 },
        .text = "bl #0x200004e",
        .symbol = "",
    };

    try disasm_wire.put(&buf, &at, r1);
    try disasm_wire.put(&buf, &at, r2);

    var reader: disasm_wire.Reader = .{ .rest = buf[0..at] };
    const d1 = (try reader.next()).?;
    try std.testing.expectEqual(r1.address, d1.address);
    try std.testing.expectEqual(r1.size, d1.size);
    try std.testing.expectEqual(r1.decoded, d1.decoded);
    try std.testing.expectEqualSlices(u8, &r1.raw, &d1.raw);
    try std.testing.expectEqualStrings(r1.text, d1.text);
    try std.testing.expectEqualStrings(r1.symbol, d1.symbol);

    const d2 = (try reader.next()).?;
    try std.testing.expectEqual(r2.address, d2.address);
    try std.testing.expectEqual(r2.size, d2.size);
    try std.testing.expectEqualStrings(r2.text, d2.text);
    try std.testing.expectEqualStrings("", d2.symbol);
    try std.testing.expectEqual(@as(?proto.DisasmRow, null), try reader.next());
}

test "Disasmwire rejects truncated buffers" {
    var reader: disasm_wire.Reader = .{ .rest = &.{ 1, 2, 3 } };
    try std.testing.expectError(error.Truncated, reader.next());
}
