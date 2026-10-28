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
