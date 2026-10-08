//! Covers src/snapshot/fields.zig.
const std = @import("std");
const ra8 = @import("ra8");
const fields = ra8.snapshot.fields;

const Mode = enum(u2) { idle, busy, done };
const Flags = packed struct(u8) { a: u1 = 0, b: u3 = 0, rest: u4 = 0 };
const Sample = struct {
    small: u9,
    signed: i16,
    on: bool,
    mode: Mode,
    flags: Flags,
    list: [3]u32,
    maybe: ?u32,
    never: ?Mode,
};

test "every supported kind of field reads back as written" {
    const value: Sample = .{ .small = 0x1A5, .signed = -2, .on = true, .mode = .done, .flags = .{ .a = 1, .b = 5, .rest = 9 }, .list = .{ 1, 0xFFFF_FFFF, 7 }, .maybe = 0xDEAD_BEEF, .never = null };
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try fields.write(&list.writer, value);
    // u9 2, i16 2, bool 1, enum 1, packed 1, array 12, optional 5, null 1.
    try std.testing.expectEqual(@as(usize, 25), list.written().len);
    var cursor: fields.Cursor = .{ .bytes = list.written() };
    try std.testing.expectEqualDeep(value, try fields.read(Sample, &cursor));
    try std.testing.expect(cursor.done());
}

test "a short payload is Truncated" {
    var cursor: fields.Cursor = .{ .bytes = &.{ 1, 2, 3 } };
    try std.testing.expectError(error.Truncated, fields.read(u32, &cursor));
}

test "a value outside its field's type is BadValue" {
    var wide: fields.Cursor = .{ .bytes = &.{ 0xFF, 0x03 } };
    try std.testing.expectError(error.BadValue, fields.read(u9, &wide));
    var flag: fields.Cursor = .{ .bytes = &.{2} };
    try std.testing.expectError(error.BadValue, fields.read(bool, &flag));
    var mode: fields.Cursor = .{ .bytes = &.{3} };
    try std.testing.expectError(error.BadValue, fields.read(Mode, &mode));
    var tag: fields.Cursor = .{ .bytes = &.{ 9, 0, 0, 0, 0 } };
    try std.testing.expectError(error.BadValue, fields.read(?u32, &tag));
}

const Why = enum(u8) { bad_size, bad_mode };
const Reason = union(enum) { stopped, spent, unsupported: Why };

test "a tagged union reads back as its tag and active payload" {
    const values = [_]Reason{ .stopped, .spent, .{ .unsupported = .bad_mode } };
    for (values) |value| {
        var list = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer list.deinit();
        try fields.write(&list.writer, value);
        var cursor: fields.Cursor = .{ .bytes = list.written() };
        try std.testing.expectEqual(value, try fields.read(Reason, &cursor));
        try std.testing.expect(cursor.done());
    }
}

test "a union tag outside its type is BadValue" {
    var cursor: fields.Cursor = .{ .bytes = &.{9} };
    try std.testing.expectError(error.BadValue, fields.read(Reason, &cursor));
}

const Leaf = struct { keep: u8, wire: *const u8 };
const Holder = struct { head: u16, items: [2]Leaf, one: Leaf };
const leaf_skip = .{ "items.wire", "one.wire" };
const wire_a: u8 = 1;
const wire_b: u8 = 2;

fn holder(head: u16, keep: u8, wire: *const u8) Holder {
    const leaf: Leaf = .{ .keep = keep, .wire = wire };
    return .{ .head = head, .items = .{ leaf, .{ .keep = keep + 1, .wire = wire } }, .one = leaf };
}

test "a dotted skip leaves out a field inside structs and arrays" {
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try fields.writeExcept(&list.writer, holder(7, 3, &wire_a), leaf_skip);
    try std.testing.expectEqual(@as(usize, 2 + 3), list.written().len);
    var out = holder(0, 0, &wire_b);
    var cursor: fields.Cursor = .{ .bytes = list.written() };
    try fields.readOver(&cursor, &out, leaf_skip);
    try std.testing.expect(cursor.done());
    try std.testing.expectEqual(@as(u16, 7), out.head);
    try std.testing.expectEqual(@as(u8, 4), out.items[1].keep);
    try std.testing.expectEqual(@as(u8, 3), out.one.keep);
    try std.testing.expect(out.items[0].wire == &wire_b and out.one.wire == &wire_b);
}
