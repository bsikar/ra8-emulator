//! Tests for src/interfaces/rpc/locals_wire.zig (RA8EMU-805): packed rows
//! read back in order with their names, types, and where kinds, the widest
//! row fits its length byte and local_row_bytes, and a cut-off list is caught.
const std = @import("std");
const ra8 = @import("ra8");

const proto = ra8.rpc.session.rpc;
const locals_wire = ra8.rpc.locals_wire;

const long_name: [proto.local_name_cap]u8 = @splat('n');
const long_type: [proto.local_type_cap]u8 = @splat('t');
const widest: proto.LocalRow = .{
    .name = &long_name,
    .type_name = &long_type,
    .size = 0xFFFF_FFFF,
    .where_kind = proto.where_kinds.frame,
    .where_a = 0xFFFF_FFFF_FFFF_FFFF,
    .where_b = 0xFFFF_FFFF_FFFF_FFFF,
};

test "packed rows read back in order" {
    var out: [proto.locals_bytes]u8 = undefined;
    var at: usize = 0;
    try locals_wire.put(&out, &at, .{ .name = "n", .type_name = "int", .size = 4, .where_kind = proto.where_kinds.frame, .where_a = @bitCast(@as(i64, 8)), .where_b = 0 });
    try locals_wire.put(&out, &at, .{ .name = "r", .type_name = "", .size = 0, .where_kind = proto.where_kinds.in_register, .where_a = 5, .where_b = 0 });
    var reader: locals_wire.Reader = .{ .rest = out[0..at] };
    const first = (try reader.next()).?;
    try std.testing.expectEqualStrings("n", first.name);
    try std.testing.expectEqualStrings("int", first.type_name);
    try std.testing.expectEqual(@as(u32, 4), first.size);
    try std.testing.expectEqual(proto.where_kinds.frame, first.where_kind);
    try std.testing.expectEqual(@as(i64, 8), @as(i64, @bitCast(first.where_a)));
    const second = (try reader.next()).?;
    try std.testing.expectEqualStrings("r", second.name);
    try std.testing.expectEqual(@as(u8, 5), @as(u8, @truncate(second.where_a)));
    try std.testing.expectEqual(@as(?proto.LocalRow, null), try reader.next());
}

test "a full answer of the widest rows fits locals_bytes" {
    var out: [proto.locals_bytes]u8 = undefined;
    var at: usize = 0;
    for (0..proto.locals_rows) |_| try locals_wire.put(&out, &at, widest);
    try std.testing.expectEqual(proto.locals_bytes, at);
    try std.testing.expect(proto.local_row_bytes - 1 <= std.math.maxInt(u8));
    try std.testing.expectError(error.Oversize, locals_wire.put(&out, &at, widest));
}

test "a list cut short is truncated" {
    var out: [proto.local_row_bytes]u8 = undefined;
    var at: usize = 0;
    try locals_wire.put(&out, &at, widest);
    var reader: locals_wire.Reader = .{ .rest = out[0 .. at - 1] };
    try std.testing.expectError(error.Truncated, reader.next());
}
