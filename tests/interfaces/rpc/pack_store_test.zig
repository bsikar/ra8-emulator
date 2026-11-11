//! Covers src/interfaces/rpc/pack_store.zig and history_live.zig on a real
//! history session: objects wait unsealed, seal as a pack with an index,
//! read back, and compaction
//! rewrites a mostly dead pack into one of the live objects.
const std = @import("std");
const ra8 = @import("ra8");
const bind_mod = ra8.rpc.history_bind;
const pack_store = ra8.rpc.pack_store;
const ObjectId = ra8.session.history_object_id.ObjectId;
const compaction = ra8.session.history_compaction;

fn object(seed: u8) [64]u8 {
    var bytes: [64]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = seed +% @as(u8, @intCast(i));
    return bytes;
}

fn openBind(gpa: std.mem.Allocator, root: []const u8) !*bind_mod.Bind {
    return bind_mod.Bind.open(gpa, std.testing.io, root, .{ .kept = true });
}

test "objects wait unsealed, then seal into an indexed pack" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const a = object(1);
    const id_a = ObjectId.compute(&a);
    {
        const bind = try openBind(gpa, root);
        try bind.packs.put(id_a, &a);
        try std.testing.expect(bind.packs.has(id_a));
        // Still waiting: readable, but no pack is on disk yet.
        const waiting = (try bind.packs.get(gpa, id_a)).?;
        gpa.free(waiting);
        try std.testing.expectEqual(@as(usize, 0), bind.packs.sealed.items.len);
        try bind.packs.seal();
        try std.testing.expectEqual(@as(usize, 1), bind.packs.sealed.items.len);
        const got = (try bind.packs.get(gpa, id_a)).?;
        defer gpa.free(got);
        try std.testing.expectEqualSlices(u8, &a, got);
        _ = bind.close() catch {};
    }
}

test "compaction rewrites a mostly dead pack into the live objects" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const bind = try openBind(gpa, root);
    defer _ = bind.close() catch {};
    const packs = bind.packs;
    var ids: [4]ObjectId = undefined;
    for (&ids, 0..) |*id, i| {
        const bytes = object(@intCast(i * 7 + 1));
        id.* = ObjectId.compute(&bytes);
        try packs.put(id.*, &bytes);
    }
    try packs.seal();
    // One of four objects is live: 75% of the pack is garbage.
    var live = compaction.LiveSet.init(gpa);
    defer live.deinit();
    try live.put(ids[2].bytes, {});
    const report = try packs.compact(&live);
    try std.testing.expectEqual(@as(usize, 1), report.packs_removed);
    try std.testing.expectEqual(@as(usize, 1), report.objects_copied);
    try std.testing.expect(report.bytes_after < report.bytes_before);
    try std.testing.expect(packs.has(ids[2]));
    try std.testing.expect(!packs.has(ids[0]));
    const bytes = object(2 * 7 + 1);
    const kept = (try packs.get(gpa, ids[2])).?;
    defer gpa.free(kept);
    try std.testing.expectEqualSlices(u8, &bytes, kept);

    // Everything live: nothing to do.
    try live.put(ids[2].bytes, {});
    const again = try packs.compact(&live);
    try std.testing.expectEqual(@as(usize, 0), again.packs_removed);
}

test "put refuses corrupt sealed pack payload without overwriting" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const a = object(11);
    const id_a = ObjectId.compute(&a);

    const bind = try openBind(gpa, root);
    defer _ = bind.close() catch {};
    try bind.packs.put(id_a, &a);
    try bind.packs.seal();

    var leaf_buf: [32]u8 = undefined;
    const pack_leaf = try pack_store.packName(&leaf_buf, 1, "pack");
    const store = ra8.host.history.storage.Store.from(&bind.session);
    const before = try ra8.rpc.object_read.read(store, gpa, pack_leaf);
    defer gpa.free(before);

    var corrupted = try gpa.dupe(u8, before);
    defer gpa.free(corrupted);
    corrupted[ra8.session.history_pack.header_len + ra8.session.history_pack.record_header_len] ^= 0x01;
    {
        const file = try store.vtable.open(store.context, .objects, pack_leaf, .update);
        defer file.vtable.close(file.context);
        try file.vtable.write(file.context, 0, corrupted);
        try file.vtable.sync(file.context);
    }

    try std.testing.expectError(error.CorruptCrc, bind.packs.put(id_a, &a));
    try std.testing.expectEqual(@as(usize, 0), bind.packs.entries.items.len);
    const after = try ra8.rpc.object_read.read(store, gpa, pack_leaf);
    defer gpa.free(after);
    try std.testing.expectEqualSlices(u8, corrupted, after);
}

test "put refuses pending full-byte mismatch and forged fresh identity" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const a = object(21);
    const b = object(39);
    const id_a = ObjectId.compute(&a);
    const id_c = ObjectId.compute("other genuine payload");

    const bind = try openBind(gpa, root);
    defer _ = bind.close() catch {};

    try std.testing.expectError(error.ForgedIdentity, bind.packs.put(id_c, &b));
    try std.testing.expect(!bind.packs.has(id_c));

    try bind.packs.put(id_a, &a);
    try std.testing.expectError(error.ObjectConflict, bind.packs.put(id_a, &b));
    const still_a = (try bind.packs.get(gpa, id_a)).?;
    defer gpa.free(still_a);
    try std.testing.expectEqualSlices(u8, &a, still_a);
}

test "get refuses forged CRC-valid index pointing idA at record B" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const a = object(51);
    const b = object(77);
    const id_a = ObjectId.compute(&a);
    const id_b = ObjectId.compute(&b);

    const bind = try openBind(gpa, root);
    defer _ = bind.close() catch {};
    try bind.packs.put(id_b, &b);
    try bind.packs.seal();

    const entry_b = bind.packs.sealed.items[0].lookup(id_b).?;
    const forged_entries = [_]ra8.session.history_pack_index.Entry{.{
        .object_id = id_a,
        .xxh3_prefilter = id_a.prefilter(),
        .pack_offset = entry_b.pack_offset,
        .compressed_len = entry_b.compressed_len,
        .uncompressed_len = entry_b.uncompressed_len,
    }};
    var idx_buf: std.Io.Writer.Allocating = .init(gpa);
    defer idx_buf.deinit();
    try ra8.session.history_pack_index.encode(gpa, &idx_buf.writer, 1, &forged_entries);

    var leaf_buf: [32]u8 = undefined;
    const idx_leaf = try pack_store.packName(&leaf_buf, 1, "idx");
    try ra8.host.history.pack_file.writeAtomic(&bind.session, idx_leaf, idx_buf.written());

    const reopened = try pack_store.PackStore.open(gpa, &bind.session);
    defer reopened.close();
    try std.testing.expectError(error.ForgedIdentity, reopened.get(gpa, id_a));
    try std.testing.expectError(error.ForgedIdentity, reopened.put(id_a, &a));
}
