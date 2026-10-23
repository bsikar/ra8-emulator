//! Robustness tests for pack record framing, CRC verification, and forged hash refusal.
const std = @import("std");
const ra8 = @import("ra8");
const pack = ra8.session.history_pack;
const ObjectId = ra8.session.history_object_id.ObjectId;
const Crc32c = std.hash.crc.@"CRC-32/ISCSI";

test "Pack header encode and readHeader round trip" {
    var buf: [pack.header_len]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buf);
    try pack.writeHeader(&stream, 42);

    const pack_id = try pack.readHeader(&buf);
    try std.testing.expectEqual(@as(u32, 42), pack_id);

    try std.testing.expectError(error.TruncatedPack, pack.readHeader(buf[0..10]));
    var bad_magic = buf;
    bad_magic[0] = 'X';
    try std.testing.expectError(error.BadMagic, pack.readHeader(&bad_magic));
}

test "Pack record encode and decode round trip with flate1" {
    const allocator = std.testing.allocator;
    var payload: [4096]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i % 17); // highly compressible pattern
    const id = ObjectId.compute(&payload);

    var list: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
    defer list.deinit();

    const written = try pack.encodeRecord(allocator, &list.writer, id, pack.flags.page, &payload);
    try std.testing.expectEqual(written, list.written().len);

    const res = try pack.decodeRecordFromSlice(allocator, list.written());
    var rec = res.record;
    defer rec.deinit(allocator);

    try std.testing.expect(rec.object_id.eql(id));
    try std.testing.expectEqual(pack.flags.page, rec.flags);
    try std.testing.expectEqualSlices(u8, &payload, rec.data);
    try std.testing.expect(rec.compressed_len < payload.len);
}

test "Pack robustness: truncated pack refuses with TruncatedPack" {
    const allocator = std.testing.allocator;
    const payload = "Truncation test payload";
    const id = ObjectId.compute(payload);

    var list: std.Io.Writer.Allocating = try .initCapacity(allocator, 128);
    defer list.deinit();
    _ = try pack.encodeRecord(allocator, &list.writer, id, pack.flags.blob, payload);
    const full = list.written();

    // 1. Truncate in record header
    try std.testing.expectError(error.TruncatedPack, pack.decodeRecordFromSlice(allocator, full[0..15]));
    // 2. Truncate in payload
    try std.testing.expectError(error.TruncatedPack, pack.decodeRecordFromSlice(allocator, full[0 .. full.len - 3]));
}

test "Pack robustness: flipped bit in payload refuses with CorruptCrc" {
    const allocator = std.testing.allocator;
    const payload = "Corrupt CRC bit flip test payload";
    const id = ObjectId.compute(payload);

    var list: std.Io.Writer.Allocating = try .initCapacity(allocator, 128);
    defer list.deinit();
    _ = try pack.encodeRecord(allocator, &list.writer, id, pack.flags.blob, payload);

    var corrupted = try allocator.dupe(u8, list.written());
    defer allocator.free(corrupted);

    // Flip bit in the payload area
    corrupted[pack.record_header_len + 2] ^= 0x01;

    try std.testing.expectError(error.CorruptCrc, pack.decodeRecordFromSlice(allocator, corrupted));
}

test "Pack robustness: forged identity refuses with ForgedIdentity" {
    const allocator = std.testing.allocator;
    const genuine_payload = "Genuine data that has an authentic Blake3 hash";
    const forged_payload = "Forged data attempting to masquerade under genuine id";
    const genuine_id = ObjectId.compute(genuine_payload);

    // Craft a forged packet that carries genuine_id in header, but forged_payload in uncompressed body,
    // with CRC correctly computed over the forged packet to pass CRC check.
    var forged_buf: [pack.record_overhead + forged_payload.len]u8 = undefined;
    @memcpy(forged_buf[0..16], &genuine_id.bytes);
    std.mem.writeInt(u32, forged_buf[16..20], @intCast(forged_payload.len), .little);
    std.mem.writeInt(u32, forged_buf[20..24], @intCast(forged_payload.len), .little);
    forged_buf[24] = 0; // uncompressed
    forged_buf[25] = pack.flags.blob;
    forged_buf[26] = 0;
    forged_buf[27] = 0;
    @memcpy(forged_buf[pack.record_header_len .. pack.record_header_len + forged_payload.len], forged_payload);

    var crc = Crc32c.init();
    crc.update(forged_buf[0 .. pack.record_header_len + forged_payload.len]);
    std.mem.writeInt(u32, forged_buf[pack.record_header_len + forged_payload.len ..][0..4], crc.final(), .little);

    // Decoding must reject with ForgedIdentity because computed hash does not match genuine_id
    try std.testing.expectError(error.ForgedIdentity, pack.decodeRecordFromSlice(allocator, &forged_buf));
}
