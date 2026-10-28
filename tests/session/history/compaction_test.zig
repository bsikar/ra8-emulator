//! Tests for pack file compaction planning, garbage ratio threshold, and cross-line liveness.
const std = @import("std");
const ra8 = @import("ra8");
const compaction = ra8.session.history_compaction;
const ObjectId = ra8.session.history_object_id.ObjectId;
const pack_index = ra8.session.history_pack_index;
const manifest_mod = ra8.session.history_manifest;
const Position = ra8.chip.core.scheduler.Position;

test "compaction shouldCompact boundary at exactly 30%" {
    // 0 out of 100: 0% -> false
    try std.testing.expect(!compaction.shouldCompact(0, 100));
    // 29 out of 100: 29% -> false
    try std.testing.expect(!compaction.shouldCompact(29, 100));
    // 30 out of 100: exactly 30% -> false (boundary test: strictly > 30% required)
    try std.testing.expect(!compaction.shouldCompact(30, 100));
    // 31 out of 100: 31% -> true
    try std.testing.expect(compaction.shouldCompact(31, 100));
    // 300 out of 1000: exactly 30% -> false
    try std.testing.expect(!compaction.shouldCompact(300, 1000));
    // 301 out of 1000: 30.1% -> true
    try std.testing.expect(compaction.shouldCompact(301, 1000));
}

test "compaction planCompaction triggers only on packs exceeding 30% garbage" {
    const allocator = std.testing.allocator;

    var live_set = compaction.LiveSet.init(allocator);
    defer live_set.deinit();

    const obj_live1 = ObjectId.compute("live_object_1");
    const obj_live2 = ObjectId.compute("live_object_2");
    const obj_dead1 = ObjectId.compute("dead_object_1");
    const obj_dead2 = ObjectId.compute("dead_object_2");

    try live_set.put(obj_live1.bytes, {});
    try live_set.put(obj_live2.bytes, {});

    // Pack 1: 2 live objects, 0 dead objects (0% dead -> no compaction)
    var entries_pack1 = [_]pack_index.Entry{
        .{ .object_id = obj_live1, .xxh3_prefilter = 0, .pack_offset = 0, .compressed_len = 100, .uncompressed_len = 200 },
        .{ .object_id = obj_live2, .xxh3_prefilter = 0, .pack_offset = 132, .compressed_len = 100, .uncompressed_len = 200 },
    };
    const pack1 = pack_index.Index{ .pack_id = 1, .entries = &entries_pack1 };

    // Pack 2: 1 live object, 2 dead objects (~66% dead -> triggers compaction)
    var entries_pack2 = [_]pack_index.Entry{
        .{ .object_id = obj_live1, .xxh3_prefilter = 0, .pack_offset = 0, .compressed_len = 100, .uncompressed_len = 200 },
        .{ .object_id = obj_dead1, .xxh3_prefilter = 0, .pack_offset = 132, .compressed_len = 100, .uncompressed_len = 200 },
        .{ .object_id = obj_dead2, .xxh3_prefilter = 0, .pack_offset = 264, .compressed_len = 100, .uncompressed_len = 200 },
    };
    const pack2 = pack_index.Index{ .pack_id = 2, .entries = &entries_pack2 };

    const packs = [_]pack_index.Index{ pack1, pack2 };
    var plan = try compaction.planCompaction(allocator, &packs, &live_set, 10);
    defer plan.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 10), plan.new_pack_id);
    // Only pack 2 should be marked obsolete
    try std.testing.expectEqual(@as(usize, 1), plan.obsolete_packs.len);
    try std.testing.expectEqual(@as(u32, 2), plan.obsolete_packs[0]);
    // The single live object from pack 2 should be copied
    try std.testing.expectEqual(@as(usize, 1), plan.copy_objects.len);
    try std.testing.expect(plan.copy_objects[0].object_id.eql(obj_live1));
    try std.testing.expectEqual(@as(u32, 2), plan.copy_objects[0].pack_id);
}

test "compaction cross-line liveness keeps objects referenced only by non-active branches" {
    const allocator = std.testing.allocator;

    const obj_branch0 = ObjectId.compute("branch0_only_obj");
    const obj_branch1 = ObjectId.compute("branch1_only_obj");
    const obj_orphaned = ObjectId.compute("orphaned_obj");

    // Manifest for Branch 0 (non-active line)
    var pages0 = [_]manifest_mod.PageRef{
        .{ .space = .cpu0_sram, .page_index = 0, .object = obj_branch0 },
    };
    const m0 = manifest_mod.Manifest{
        .position = Position{ .branch = 0, .r = 10 },
        .checkpoint_id = 1,
        .picture = null,
        .pages = &pages0,
        .blobs = &.{},
        .root_hash = ObjectId.zero,
    };

    // Manifest for Branch 1 (active line)
    var pages1 = [_]manifest_mod.PageRef{
        .{ .space = .cpu0_sram, .page_index = 0, .object = obj_branch1 },
    };
    const m1 = manifest_mod.Manifest{
        .position = Position{ .branch = 1, .r = 20 },
        .checkpoint_id = 2,
        .picture = null,
        .pages = &pages1,
        .blobs = &.{},
        .root_hash = ObjectId.zero,
    };

    const manifests = [_]*const manifest_mod.Manifest{ &m0, &m1 };
    var live_set = try compaction.buildLiveSet(allocator, &manifests, &.{});
    defer live_set.deinit();

    // Verify both branch objects are live
    try std.testing.expect(live_set.contains(obj_branch0.bytes));
    try std.testing.expect(live_set.contains(obj_branch1.bytes));
    try std.testing.expect(!live_set.contains(obj_orphaned.bytes));

    // Pack with all three objects (1/3 dead = 33.3% > 30% -> compacts)
    var pack_entries = [_]pack_index.Entry{
        .{ .object_id = obj_branch0, .xxh3_prefilter = 0, .pack_offset = 0, .compressed_len = 100, .uncompressed_len = 100 },
        .{ .object_id = obj_branch1, .xxh3_prefilter = 0, .pack_offset = 132, .compressed_len = 100, .uncompressed_len = 100 },
        .{ .object_id = obj_orphaned, .xxh3_prefilter = 0, .pack_offset = 264, .compressed_len = 100, .uncompressed_len = 100 },
    };
    const pack = pack_index.Index{ .pack_id = 5, .entries = &pack_entries };

    var plan = try compaction.planCompaction(allocator, &.{pack}, &live_set, 99);
    defer plan.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), plan.obsolete_packs.len);
    // Both live objects from Branch 0 and Branch 1 must be preserved in copy_objects
    try std.testing.expectEqual(@as(usize, 2), plan.copy_objects.len);
}

test "compaction deduplicates live objects present in multiple obsolete packs" {
    const allocator = std.testing.allocator;

    var live_set = compaction.LiveSet.init(allocator);
    defer live_set.deinit();

    const obj_live1 = ObjectId.compute("live_object_1");
    const obj_dead1 = ObjectId.compute("dead_object_1");
    const obj_dead2 = ObjectId.compute("dead_object_2");

    try live_set.put(obj_live1.bytes, {});

    // Pack 1: contains obj_live1 and obj_dead1 (50% dead -> compacts)
    var entries_pack1 = [_]pack_index.Entry{
        .{ .object_id = obj_live1, .xxh3_prefilter = 0, .pack_offset = 0, .compressed_len = 100, .uncompressed_len = 200 },
        .{ .object_id = obj_dead1, .xxh3_prefilter = 0, .pack_offset = 132, .compressed_len = 100, .uncompressed_len = 200 },
    };
    const pack1 = pack_index.Index{ .pack_id = 1, .entries = &entries_pack1 };

    // Pack 2: ALSO contains obj_live1 and obj_dead2 (50% dead -> compacts)
    var entries_pack2 = [_]pack_index.Entry{
        .{ .object_id = obj_live1, .xxh3_prefilter = 0, .pack_offset = 0, .compressed_len = 100, .uncompressed_len = 200 },
        .{ .object_id = obj_dead2, .xxh3_prefilter = 0, .pack_offset = 132, .compressed_len = 100, .uncompressed_len = 200 },
    };
    const pack2 = pack_index.Index{ .pack_id = 2, .entries = &entries_pack2 };

    const packs = [_]pack_index.Index{ pack1, pack2 };
    var plan = try compaction.planCompaction(allocator, &packs, &live_set, 20);
    defer plan.deinit(allocator);

    // Both packs are obsolete
    try std.testing.expectEqual(@as(usize, 2), plan.obsolete_packs.len);
    // obj_live1 must appear in copy_objects EXACTLY ONCE (no duplicates)
    try std.testing.expectEqual(@as(usize, 1), plan.copy_objects.len);
    try std.testing.expect(plan.copy_objects[0].object_id.eql(obj_live1));
}
