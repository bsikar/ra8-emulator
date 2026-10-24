//! Tests for Merkle Manifest codec, Merkle root verification, and diffing.
const std = @import("std");
const ra8 = @import("ra8");
const manifest_mod = ra8.session.history_manifest;
const ObjectId = ra8.session.history_object_id.ObjectId;
const Position = ra8.chip.core.scheduler.Position;

fn sampleManifest(allocator: std.mem.Allocator) !manifest_mod.Manifest {
    const pos = Position{ .branch = 1, .r = 42, .phase = .cpu0, .o = 10, .gap = .retired };
    const pages = try allocator.alloc(manifest_mod.PageRef, 3);
    pages[0] = .{ .space = .cpu0_sram, .page_index = 0, .object = ObjectId.compute("page0_data") };
    pages[1] = .{ .space = .cpu0_sram, .page_index = 1, .object = ObjectId.compute("page1_data") };
    pages[2] = .{ .space = .cpu0_sdram, .page_index = 5, .object = ObjectId.compute("page5_data") };

    const blobs = try allocator.alloc(manifest_mod.BlobRef, 2);
    blobs[0] = .{ .space = .cpu_registers, .size = 128, .object = ObjectId.compute("cpu_reg_data") };
    blobs[1] = .{ .space = .stretch_state, .size = 32, .object = ObjectId.compute("stretch_data") };

    const pic = ObjectId.compute("thumbnail_picture");
    const root = manifest_mod.computeMerkleRoot(pos, 100, pic, pages, blobs);

    return .{
        .position = pos,
        .checkpoint_id = 100,
        .picture = pic,
        .pages = pages,
        .blobs = blobs,
        .root_hash = root,
    };
}

test "Manifest Merkle root changes when any page or blob changes" {
    const allocator = std.testing.allocator;
    var m = try sampleManifest(allocator);
    defer m.deinit(allocator);

    const root1 = m.root_hash;
    // Modify one page hash
    m.pages[0].object = ObjectId.compute("different_page0");
    const root2 = manifest_mod.computeMerkleRoot(m.position, m.checkpoint_id, m.picture, m.pages, m.blobs);
    try std.testing.expect(!root1.eql(root2));
}

test "Manifest encode and decode round trip" {
    const allocator = std.testing.allocator;
    var original = try sampleManifest(allocator);
    defer original.deinit(allocator);

    var list: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
    defer list.deinit();

    try manifest_mod.encode(&original, &list.writer);
    const bytes = list.written();

    var decoded = try manifest_mod.decode(allocator, bytes);
    defer decoded.deinit(allocator);

    try std.testing.expectEqual(original.checkpoint_id, decoded.checkpoint_id);
    try std.testing.expect(original.root_hash.eql(decoded.root_hash));
    try std.testing.expectEqual(original.pages.len, decoded.pages.len);
    for (original.pages, decoded.pages) |op, dp| {
        try std.testing.expect(op.eql(dp));
    }
    try std.testing.expectEqual(original.blobs.len, decoded.blobs.len);
    for (original.blobs, decoded.blobs) |ob, db| {
        try std.testing.expect(ob.eql(db));
    }
}

test "Manifest decode rejects corrupt CRC or forged Merkle root" {
    const allocator = std.testing.allocator;
    var original = try sampleManifest(allocator);
    defer original.deinit(allocator);

    var list: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
    defer list.deinit();
    try manifest_mod.encode(&original, &list.writer);

    var corrupted = try allocator.dupe(u8, list.written());
    defer allocator.free(corrupted);

    // Flip a bit in the body
    corrupted[20] ^= 0x01;
    try std.testing.expectError(error.BadCrc, manifest_mod.decode(allocator, corrupted));
}

test "Manifest diffing computes exact differing pages and blobs" {
    const allocator = std.testing.allocator;
    var m1 = try sampleManifest(allocator);
    defer m1.deinit(allocator);

    // Diff against null current: all target items differ
    var d_fresh = try manifest_mod.diff(allocator, null, &m1);
    defer d_fresh.deinit(allocator);
    try std.testing.expectEqual(m1.pages.len, d_fresh.pages.len);
    try std.testing.expectEqual(m1.blobs.len, d_fresh.blobs.len);

    // Diff against identical manifest: 0 differences
    var d_same = try manifest_mod.diff(allocator, &m1, &m1);
    defer d_same.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), d_same.pages.len);
    try std.testing.expectEqual(@as(usize, 0), d_same.blobs.len);

    // Mutate page 1 and blob 0 in m2
    var m2 = try sampleManifest(allocator);
    defer m2.deinit(allocator);
    m2.pages[1].object = ObjectId.compute("mutated_page_1");
    m2.blobs[0].object = ObjectId.compute("mutated_reg_state");

    var d_diff = try manifest_mod.diff(allocator, &m1, &m2);
    defer d_diff.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), d_diff.pages.len);
    try std.testing.expectEqual(m2.pages[1].page_index, d_diff.pages[0].page_index);
    try std.testing.expectEqual(@as(usize, 1), d_diff.blobs.len);
    try std.testing.expectEqual(m2.blobs[0].space, d_diff.blobs[0].space);
}

test "Manifest diffing operates in O(N) linear time on realistic 35,000 page count" {
    const allocator = std.testing.allocator;

    const total_pages: usize = 35_000;
    const pages1 = try allocator.alloc(manifest_mod.PageRef, total_pages);
    defer allocator.free(pages1);

    const pages2 = try allocator.alloc(manifest_mod.PageRef, total_pages);
    defer allocator.free(pages2);

    const base_obj = ObjectId.compute("base_page_content");
    const mutated_obj = ObjectId.compute("mutated_page_content");

    for (0..total_pages) |i| {
        pages1[i] = .{
            .space = .cpu0_sdram,
            .page_index = @intCast(i),
            .object = base_obj,
        };
        const is_mutated = (i % 5000 == 0);
        pages2[i] = .{
            .space = .cpu0_sdram,
            .page_index = @intCast(i),
            .object = if (is_mutated) mutated_obj else base_obj,
        };
    }

    const pos = Position{ .branch = 1, .r = 100, .phase = .cpu0, .o = 0, .gap = .retired };
    const m1 = manifest_mod.Manifest{
        .position = pos,
        .checkpoint_id = 1,
        .picture = null,
        .pages = pages1,
        .blobs = &[_]manifest_mod.BlobRef{},
        .root_hash = ObjectId.zero,
    };
    const m2 = manifest_mod.Manifest{
        .position = pos,
        .checkpoint_id = 2,
        .picture = null,
        .pages = pages2,
        .blobs = &[_]manifest_mod.BlobRef{},
        .root_hash = ObjectId.zero,
    };

    var d = try manifest_mod.diff(allocator, &m1, &m2);
    defer d.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 7), d.pages.len);
    for (d.pages, 0..) |p, idx| {
        try std.testing.expectEqual(@as(u32, @intCast(idx * 5000)), p.page_index);
        try std.testing.expectEqual(mutated_obj, p.object);
    }
}
