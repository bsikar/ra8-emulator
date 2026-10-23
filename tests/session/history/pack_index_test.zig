//! Tests for pack index sorted lookup and index rebuild from pack after index loss.
const std = @import("std");
const ra8 = @import("ra8");
const pack = ra8.session.history_pack;
const pack_index = ra8.session.history_pack_index;
const ObjectId = ra8.session.history_object_id.ObjectId;

test "Pack index encode and decode round trip" {
    const allocator = std.testing.allocator;

    const id1 = ObjectId.compute("Object 1 data");
    const id2 = ObjectId.compute("Object 2 data");
    const id3 = ObjectId.compute("Object 3 data");

    const entries = [_]pack_index.Entry{
        .{ .object_id = id1, .xxh3_prefilter = id1.prefilter(), .pack_offset = 32, .compressed_len = 10, .uncompressed_len = 12 },
        .{ .object_id = id2, .xxh3_prefilter = id2.prefilter(), .pack_offset = 74, .compressed_len = 20, .uncompressed_len = 25 },
        .{ .object_id = id3, .xxh3_prefilter = id3.prefilter(), .pack_offset = 126, .compressed_len = 15, .uncompressed_len = 18 },
    };

    var list: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
    defer list.deinit();

    try pack_index.encode(allocator, &list.writer, 1, &entries);

    var idx = try pack_index.decode(allocator, list.written());
    defer idx.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), idx.pack_id);
    try std.testing.expectEqual(@as(usize, 3), idx.entries.len);

    const hit = idx.lookup(id2);
    try std.testing.expect(hit != null);
    try std.testing.expect(hit.?.object_id.eql(id2));
    try std.testing.expectEqual(@as(u64, 74), hit.?.pack_offset);

    const miss = idx.lookup(ObjectId.compute("Non existent"));
    try std.testing.expect(miss == null);
}

test "Pack index robustness: index rebuild from pack after index loss" {
    const allocator = std.testing.allocator;

    // 1. Build a synthetic pack containing 3 objects
    var pack_out: std.Io.Writer.Allocating = try .initCapacity(allocator, 512);
    defer pack_out.deinit();

    try pack.writeHeader(&pack_out.writer, 7);

    const data_a = "Payload A for pack reconstruction test";
    const data_b = "Payload B: another item in the pack";
    const data_c = "Payload C: a third object for recovery";

    const id_a = ObjectId.compute(data_a);
    const id_b = ObjectId.compute(data_b);
    const id_c = ObjectId.compute(data_c);

    _ = try pack.encodeRecord(allocator, &pack_out.writer, id_a, pack.flags.page, data_a);
    _ = try pack.encodeRecord(allocator, &pack_out.writer, id_b, pack.flags.blob, data_b);
    _ = try pack.encodeRecord(allocator, &pack_out.writer, id_c, pack.flags.page, data_c);

    const raw_pack = pack_out.written();

    // 2. Rebuild index from the raw pack bytes (simulating index loss)
    var rebuilt = try pack_index.rebuildFromPack(allocator, raw_pack);
    defer rebuilt.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 7), rebuilt.pack_id);
    try std.testing.expectEqual(@as(usize, 3), rebuilt.entries.len);

    // 3. Verify lookup on each object in the rebuilt index
    const hit_a = rebuilt.lookup(id_a);
    try std.testing.expect(hit_a != null);
    try std.testing.expect(hit_a.?.object_id.eql(id_a));

    const hit_b = rebuilt.lookup(id_b);
    try std.testing.expect(hit_b != null);
    try std.testing.expect(hit_b.?.object_id.eql(id_b));

    const hit_c = rebuilt.lookup(id_c);
    try std.testing.expect(hit_c != null);
    try std.testing.expect(hit_c.?.object_id.eql(id_c));

    // 4. Verify decoded record at the recorded pack_offset matches genuine data
    const rec_b_slice = raw_pack[hit_b.?.pack_offset..];
    const decoded_b_res = try pack.decodeRecordFromSlice(allocator, rec_b_slice);
    var rec_b = decoded_b_res.record;
    defer rec_b.deinit(allocator);
    try std.testing.expectEqualStrings(data_b, rec_b.data);
}
