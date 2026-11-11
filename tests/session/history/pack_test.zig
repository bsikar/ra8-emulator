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

test "Pack and index deterministic bitflip and truncate corpus never panics or leaks" {
    const allocator = std.testing.allocator;
    const pack_index = ra8.session.history_pack_index;

    const payload = "Deterministic fuzz target payload for pack, index, and manifest codecs";
    const id = ObjectId.compute(payload);
    var pack_buf: std.Io.Writer.Allocating = .init(allocator);
    defer pack_buf.deinit();
    try pack.writeHeader(&pack_buf.writer, 7);
    _ = try pack.encodeRecord(allocator, &pack_buf.writer, id, pack.flags.page, payload);
    const valid_pack = pack_buf.written();

    for (0..valid_pack.len) |cut| {
        if (pack_index.rebuildFromPack(allocator, valid_pack[0..cut])) |*idx| {
            var mut = idx.*;
            mut.deinit(allocator);
            return error.UnexpectedSuccessOnTruncatedPack;
        } else |_| {}
    }
    for (0..valid_pack.len) |pos| {
        const mutated = try allocator.dupe(u8, valid_pack);
        defer allocator.free(mutated);
        mutated[pos] ^= 0x80;
        if (pack_index.rebuildFromPack(allocator, mutated)) |*idx| {
            var mut = idx.*;
            const ok = (pos >= 12 and pos < 16 and mut.pack_id != 7) or (pos >= 16 and pos < pack.header_len and mut.pack_id == 7);
            mut.deinit(allocator);
            if (!ok) return error.UnexpectedSuccessOnBitflippedPack;
        } else |_| {}
    }
}

test "Manifest bitflip/truncate and seeded PRNG fuzz corpus never panics or leaks" {
    const allocator = std.testing.allocator;
    const pack_index = ra8.session.history_pack_index;
    const manifest = ra8.session.history_manifest;
    const id = ObjectId.compute("Deterministic fuzz target payload for pack, index, and manifest codecs");

    var pages = [_]manifest.PageRef{.{ .space = .cpu0_sram, .page_index = 0, .object = id }};
    const pos0 = ra8.chip.core.scheduler.Position{ .branch = 0, .r = 5 };
    const m = manifest.Manifest{
        .position = pos0,
        .checkpoint_id = 1,
        .picture = null,
        .pages = &pages,
        .blobs = &.{},
        .root_hash = manifest.computeMerkleRoot(pos0, 1, null, &pages, &.{}),
    };
    var man_buf: std.Io.Writer.Allocating = .init(allocator);
    defer man_buf.deinit();
    try manifest.encode(&m, &man_buf.writer);
    const valid_man = man_buf.written();
    for (0..valid_man.len) |cut| {
        if (manifest.decode(allocator, valid_man[0..cut])) |*dec| {
            var mut = dec.*;
            mut.deinit(allocator);
            return error.UnexpectedSuccessOnTruncatedManifest;
        } else |_| {}
    }
    for (0..valid_man.len) |pos| {
        const mutated = try allocator.dupe(u8, valid_man);
        defer allocator.free(mutated);
        mutated[pos] ^= 0x01;
        if (manifest.decode(allocator, mutated)) |*dec| {
            var mut = dec.*;
            mut.deinit(allocator);
            return error.UnexpectedSuccessOnBitflippedManifest;
        } else |_| {}
    }

    var prng = std.Random.DefaultPrng.init(0x5EED_CAFE_1234_5678);
    const rng = prng.random();
    var noise: [160]u8 = undefined;
    for (0..128) |len_seed| {
        const n = len_seed % (noise.len + 1);
        rng.bytes(noise[0..n]);
        if (pack.decodeRecordFromSlice(allocator, noise[0..n])) |res| {
            var r = res.record;
            r.deinit(allocator);
        } else |_| {}
        if (pack_index.decode(allocator, noise[0..n])) |*idx| {
            var mut = idx.*;
            mut.deinit(allocator);
        } else |_| {}
        if (manifest.decode(allocator, noise[0..n])) |*dec| {
            var mut = dec.*;
            mut.deinit(allocator);
        } else |_| {}
    }
}
