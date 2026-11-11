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
    try overwriteObjectFile(store, pack_leaf, corrupted);

    try std.testing.expectError(error.CorruptCrc, bind.packs.put(id_a, &a));
    try std.testing.expectEqual(@as(usize, 0), bind.packs.entries.items.len);
    const after = try ra8.rpc.object_read.read(store, gpa, pack_leaf);
    defer gpa.free(after);
    try std.testing.expectEqualSlices(u8, corrupted, after);
}

test "put refuses pending full-byte mismatch and forged fresh identity, and get refuses forged index" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const a = object(21);
    const b = object(39);
    const id_a = ObjectId.compute(&a);
    const id_b = ObjectId.compute(&b);
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

    try bind.packs.put(id_b, &b);
    try bind.packs.seal();
    const entry_a = bind.packs.sealed.items[0].lookup(id_a).?;
    const entry_b = bind.packs.sealed.items[0].lookup(id_b).?;
    const forged_entries = [_]ra8.session.history_pack_index.Entry{
        entry_a,
        .{
            .object_id = id_c,
            .xxh3_prefilter = id_c.prefilter(),
            .pack_offset = entry_b.pack_offset,
            .compressed_len = entry_b.compressed_len,
            .uncompressed_len = entry_b.uncompressed_len,
        },
    };
    var idx_buf: std.Io.Writer.Allocating = .init(gpa);
    defer idx_buf.deinit();
    try ra8.session.history_pack_index.encode(gpa, &idx_buf.writer, 1, &forged_entries);
    try ra8.host.history.pack_file.writeAtomic(&bind.session, "pack-000001.idx", idx_buf.written());

    const reopened = try pack_store.PackStore.open(gpa, &bind.session);
    defer reopened.close();
    try std.testing.expectError(error.ForgedIdentity, reopened.get(gpa, id_c));
    try std.testing.expectError(error.ForgedIdentity, reopened.put(id_c, "other genuine payload"));
}

const PackFault = struct {
    inner: ra8.host.history.pack_file.Storage,
    fail_ext: ?[]const u8 = null,
    err: anyerror = error.NoSpaceLeft,

    fn cast(ctx: *anyopaque) *PackFault {
        return @ptrCast(@alignCast(ctx));
    }
    fn storage(self: *PackFault) ra8.host.history.pack_file.Storage {
        return .{
            .context = self,
            .append = struct {
                fn f(c: *anyopaque, l: []const u8, b: []const u8) anyerror!void {
                    return cast(c).inner.append(cast(c).inner.context, l, b);
                }
            }.f,
            .readAt = struct {
                fn f(c: *anyopaque, l: []const u8, o: u64, d: []u8) anyerror!usize {
                    return cast(c).inner.readAt(cast(c).inner.context, l, o, d);
                }
            }.f,
            .length = struct {
                fn f(c: *anyopaque, l: []const u8) anyerror!u64 {
                    return cast(c).inner.length(cast(c).inner.context, l);
                }
            }.f,
            .sync = struct {
                fn f(c: *anyopaque, l: []const u8) anyerror!void {
                    return cast(c).inner.sync(cast(c).inner.context, l);
                }
            }.f,
            .writeAtomic = struct {
                fn f(c: *anyopaque, l: []const u8, b: []const u8) anyerror!void {
                    if (cast(c).fail_ext) |ext| if (std.mem.endsWith(u8, l, ext)) return cast(c).err;
                    return cast(c).inner.writeAtomic(cast(c).inner.context, l, b);
                }
            }.f,
        };
    }
};

fn encodePageManifest(
    gpa: std.mem.Allocator,
    pos: ra8.chip.core.scheduler.Position,
    cp_id: u32,
    obj: ObjectId,
) ![]u8 {
    var pages = [_]ra8.session.history_manifest.PageRef{.{ .space = .cpu0_sram, .page_index = 0, .object = obj }};
    const man = ra8.session.history_manifest.Manifest{
        .position = pos,
        .checkpoint_id = cp_id,
        .picture = null,
        .pages = &pages,
        .blobs = &.{},
        .root_hash = ra8.session.history_manifest.computeMerkleRoot(pos, cp_id, null, &pages, &.{}),
    };
    var buf: std.Io.Writer.Allocating = .init(gpa);
    errdefer buf.deinit();
    try ra8.session.history_manifest.encode(&man, &buf.writer);
    return buf.toOwnedSlice();
}

fn overwriteObjectFile(store: ra8.host.history.storage.Store, leaf: []const u8, bytes: []const u8) !void {
    const f = try store.vtable.open(store.context, .objects, leaf, .update);
    defer f.vtable.close(f.context);
    try f.vtable.truncate(f.context, 0);
    try f.vtable.write(f.context, 0, bytes);
    try f.vtable.sync(f.context);
}

test "seal fault on pack or index is atomic, retry-idempotent, and open cleans stale tmp" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const a = object(61);
    const b = object(93);
    const id_a = ObjectId.compute(&a);
    const id_b = ObjectId.compute(&b);

    const bind = try openBind(gpa, root);
    defer _ = bind.close() catch {};
    var fault: PackFault = .{ .inner = bind.packs.bytes };
    bind.packs.bytes = fault.storage();
    defer bind.packs.bytes = fault.inner;

    try bind.packs.put(id_a, &a);
    try bind.packs.put(id_b, &b);
    const expected_len = bind.packs.building.items.len;

    fault.fail_ext = ".pack";
    try std.testing.expectError(error.NoSpaceLeft, bind.packs.seal());
    try std.testing.expectEqual(@as(usize, 0), bind.packs.sealed.items.len);
    var dir = try ra8.host.history.paths.area(&bind.session, .objects);
    defer dir.close(std.testing.io);
    try std.testing.expectError(error.FileNotFound, dir.statFile(std.testing.io, "pack-000001.pack", .{}));
    try std.testing.expectError(error.FileNotFound, dir.statFile(std.testing.io, "pack-000001.pack.tmp", .{}));

    fault.fail_ext = ".idx";
    fault.err = error.InjectedIndexFault;
    try std.testing.expectError(error.InjectedIndexFault, bind.packs.seal());
    try std.testing.expectEqual(@as(u64, expected_len), (try dir.statFile(std.testing.io, "pack-000001.pack", .{})).size);

    fault.fail_ext = null;
    try bind.packs.seal();
    try std.testing.expectEqual(@as(u64, expected_len), (try dir.statFile(std.testing.io, "pack-000001.pack", .{})).size);

    try dir.deleteFile(std.testing.io, "pack-000001.idx");
    try dir.writeFile(std.testing.io, .{ .sub_path = "pack-000002.pack.tmp", .data = "stale-crash-tmp" });
    const reopened = try pack_store.PackStore.open(gpa, &bind.session);
    defer reopened.close();
    try std.testing.expectError(error.FileNotFound, dir.statFile(std.testing.io, "pack-000002.pack.tmp", .{}));
    const got_b = (try reopened.get(gpa, id_b)).?;
    defer gpa.free(got_b);
    try std.testing.expectEqualSlices(u8, &b, got_b);
}

test "reopen refuses truncated or corrupt pack under valid idx and corrupt manifest halts compaction" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const a = object(5);
    const b = object(29);
    const id_a = ObjectId.compute(&a);
    const id_b = ObjectId.compute(&b);

    const bind = try openBind(gpa, root);
    defer _ = bind.close() catch {};
    try bind.packs.put(id_a, &a);
    try bind.packs.put(id_b, &b);
    try bind.packs.seal();

    const store = ra8.host.history.storage.Store.from(&bind.session);
    const intact = try ra8.rpc.object_read.read(store, gpa, "pack-000001.pack");
    defer gpa.free(intact);
    const e0 = bind.packs.sealed.items[0].lookup(id_a).?;
    const e1 = bind.packs.sealed.items[0].lookup(id_b).?;
    const cut: usize = @intCast(@max(e0.pack_offset + 32 + e0.compressed_len, e1.pack_offset) - 1);
    try overwriteObjectFile(store, "pack-000001.pack", intact[0..cut]);
    try std.testing.expectError(error.TruncatedPack, pack_store.PackStore.open(gpa, &bind.session));

    var bad_hdr = try gpa.dupe(u8, intact);
    defer gpa.free(bad_hdr);
    bad_hdr[0] ^= 0xFF;
    try overwriteObjectFile(store, "pack-000001.pack", bad_hdr);
    try std.testing.expectError(error.BadMagic, pack_store.PackStore.open(gpa, &bind.session));
    try overwriteObjectFile(store, "pack-000001.pack", intact);

    var rec = try ra8.session.history_recorder.Recorder.init(gpa, bind.storage, .{});
    defer rec.deinit();
    rec.observe(0);
    rec.objects = bind.objects;
    const pos0 = ra8.chip.core.scheduler.Position{ .branch = 0, .r = 2 };
    const valid_man = try encodePageManifest(gpa, pos0, 1, id_a);
    defer gpa.free(valid_man);
    try rec.checkpointRecords(.{ .position = pos0, .seq = 1 }, 1, "cp-state", null, valid_man);
    try rec.commit(1);
    valid_man[16] ^= 0x01;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("cp-state", &digest, .{});
    const man_leaf = ra8.session.history_manifest.objectName(digest[0..16].*);
    try overwriteObjectFile(store, &man_leaf, valid_man);

    try std.testing.expectError(error.BadCrc, ra8.host.history.prune.orphans(store, gpa, bind_mod.prune_referrer));
    try std.testing.expectError(error.BadCrc, ra8.rpc.history_live.compactPacksWithReferrer(store, gpa, bind.packs, bind_mod.prune_referrer));
}

test "child-safe thinning and compaction keep fork-base and child pages; ephemeral close leaves 0 bytes" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);

    const eph = try bind_mod.Bind.open(gpa, std.testing.io, root, .{ .kept = false });
    const d = object(3);
    try eph.packs.put(ObjectId.compute(&d), &d);
    try eph.packs.seal();
    try eph.storage.append(eph.storage.context, "ephemeral");
    try eph.storage.flush(eph.storage.context);
    try std.testing.expectEqual(ra8.host.history.session.Outcome.deleted, try eph.close());
    var base = try ra8.host.history.base.Base.existing(gpa, std.testing.io, root, .cache);
    var it = try ra8.host.history.catalog.Iterator.init(&base);
    try std.testing.expect((try it.next()) == null);
    base.close();

    const bind = try openBind(gpa, root);
    defer _ = bind.close() catch {};
    const store = ra8.host.history.storage.Store.from(&bind.session);
    var rec = try ra8.session.history_recorder.Recorder.init(gpa, bind.storage, .{});
    defer rec.deinit();
    rec.observe(0);
    rec.objects = bind.objects;

    const child_id = try bind.graph.addBranch(0, .{ .branch = 0, .r = 11 }, .writes, 100);
    var cnode = bind.graph.get(child_id).?;
    cnode.recorded_end = .{ .branch = child_id, .r = 40 };
    try bind.graph.insertNode(cnode);

    var ids: [6]ObjectId = undefined;
    for (&ids, 0..) |*id, i| {
        const page = object(@intCast(i * 13 + 7));
        id.* = ObjectId.compute(&page);
        try bind.packs.put(id.*, &page);
    }
    try bind.packs.seal();

    const rounds = [_]u64{ 0, 10, 12, 14, 1000, 35 };
    const branches = [_]u32{ 0, 0, 0, 0, 0, child_id };
    for (rounds, branches, 0..) |r, br, i| {
        const pos = ra8.chip.core.scheduler.Position{ .branch = br, .r = r };
        const man = try encodePageManifest(gpa, pos, @intCast(i), ids[i]);
        defer gpa.free(man);
        var sb: [16]u8 = undefined;
        const st = try std.fmt.bufPrint(&sb, "cp-{d}", .{i});
        try rec.checkpointRecords(.{ .position = pos, .seq = @intCast(i + 1) }, @intCast(i), st, null, man);
    }
    try rec.commit(1);

    const thin_rep = try ra8.rpc.history_maint.thin(gpa, store, &bind.graph, 2000);
    try std.testing.expectEqual(@as(usize, 2), thin_rep.dropped);
    try std.testing.expectError(error.NotConfirmed, ra8.rpc.history_maint.reroot(gpa, store, &bind.graph, 4, false));

    const comp_rep = try ra8.rpc.history_live.compactPacksWithReferrer(store, gpa, bind.packs, bind_mod.prune_referrer);
    try std.testing.expectEqual(@as(usize, 1), comp_rep.packs_removed);
    try std.testing.expectEqual(@as(usize, 4), comp_rep.objects_copied);
    try std.testing.expect(bind.packs.has(ids[1]) and bind.packs.has(ids[5]));
    try std.testing.expect(!bind.packs.has(ids[2]) and !bind.packs.has(ids[3]));

    const rr_rep = try ra8.rpc.history_maint.reroot(gpa, store, &bind.graph, 4, true);
    try std.testing.expectEqual(@as(usize, 2), rr_rep.dropped);
    try std.testing.expectEqual(@as(usize, 2), rr_rep.kept);
}
