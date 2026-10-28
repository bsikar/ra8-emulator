//! Tests for ObjectId Blake3-128 computation, XxHash3 prefilter, and equality.
const std = @import("std");
const ra8 = @import("ra8");
const ObjectId = ra8.session.history_object_id.ObjectId;

test "ObjectId compute produces deterministic 128-bit truncated Blake3" {
    const data = "Content-Addressed Object Test Payload";
    const id1 = ObjectId.compute(data);
    const id2 = ObjectId.compute(data);
    try std.testing.expect(id1.eql(id2));
    try std.testing.expect(!id1.eql(ObjectId.zero));

    var full: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(data, &full, .{});
    try std.testing.expectEqualSlices(u8, full[0..16], &id1.bytes);
}

test "ObjectId prefilter computes XxHash3-64 over identity bytes" {
    const id = ObjectId.compute("Test prefilter payload");
    const expected = std.hash.XxHash3.hash(0, &id.bytes);
    try std.testing.expectEqual(expected, id.prefilter());
}

test "ObjectId equal prefilter never implies equal identity" {
    var id_a = ObjectId{ .bytes = @splat(1) };
    var id_b = ObjectId{ .bytes = @splat(1) };
    id_b.bytes[15] = 2; // differ in last byte

    // Both IDs are distinct
    try std.testing.expect(!id_a.eql(id_b));

    // Even if two IDs have identical prefilter bytes, eql must inspect full 128 bits
    var id_same_pref_1 = ObjectId{ .bytes = @splat(0xaa) };
    var id_same_pref_2 = ObjectId{ .bytes = @splat(0xaa) };
    id_same_pref_2.bytes[10] = 0xbb;

    try std.testing.expect(!id_same_pref_1.eql(id_same_pref_2));
}

test "ObjectId order provides strict total ordering" {
    var id_low = ObjectId{ .bytes = @splat(0x10) };
    var id_high = ObjectId{ .bytes = @splat(0x20) };
    try std.testing.expectEqual(std.math.Order.lt, id_low.order(id_high));
    try std.testing.expectEqual(std.math.Order.gt, id_high.order(id_low));
    try std.testing.expectEqual(std.math.Order.eq, id_low.order(id_low));
}

test "ObjectId hex formatting and parsing round trip" {
    const original = ObjectId.compute("Arbitrary test bytes for hex round trip");
    var hex: [32]u8 = undefined;
    original.formatHex(&hex);

    const parsed = try ObjectId.fromHex(&hex);
    try std.testing.expect(original.eql(parsed));

    try std.testing.expectError(error.BadHex, ObjectId.fromHex("too_short"));
    try std.testing.expectError(error.BadHex, ObjectId.fromHex("1234567890123456789012345678901g"));
}
