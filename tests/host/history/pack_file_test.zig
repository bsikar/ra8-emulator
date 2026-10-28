//! Tests for host-side pack file operations in .objects space.
const std = @import("std");
const ra8 = @import("ra8");
const history = ra8.host.history;
const pack_file = history.pack_file;
const bind_mod = ra8.rpc.history_bind;

test "pack_file append, readAt, length and writeAtomic in objects space" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    const root = try temp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    const bind = try bind_mod.Bind.open(gpa, io, root, .{});
    defer _ = bind.close() catch {};

    const pack_leaf = "pack-0.pack";
    const chunk1 = "First chunk of pack data";
    const chunk2 = "Second chunk appended to pack data";

    // 1. Append first chunk
    try pack_file.append(&bind.session, pack_leaf, chunk1);
    const len1 = try pack_file.length(&bind.session, pack_leaf);
    try std.testing.expectEqual(@as(u64, chunk1.len), len1);

    // 2. Append second chunk
    try pack_file.append(&bind.session, pack_leaf, chunk2);
    const len2 = try pack_file.length(&bind.session, pack_leaf);
    try std.testing.expectEqual(@as(u64, chunk1.len + chunk2.len), len2);

    // 3. Read at offset
    var read_buf: [128]u8 = undefined;
    const got1 = try pack_file.readAt(&bind.session, pack_leaf, 0, read_buf[0..chunk1.len]);
    try std.testing.expectEqual(chunk1.len, got1);
    try std.testing.expectEqualStrings(chunk1, read_buf[0..chunk1.len]);

    const got2 = try pack_file.readAt(&bind.session, pack_leaf, chunk1.len, read_buf[0..chunk2.len]);
    try std.testing.expectEqual(chunk2.len, got2);
    try std.testing.expectEqualStrings(chunk2, read_buf[0..chunk2.len]);

    // 4. Sync
    try pack_file.sync(&bind.session, pack_leaf);

    // 5. writeAtomic for an index file
    const idx_leaf = "pack-0.idx";
    const idx_data = "Atomic index file payload";
    try pack_file.writeAtomic(&bind.session, idx_leaf, idx_data);

    const idx_len = try pack_file.length(&bind.session, idx_leaf);
    try std.testing.expectEqual(@as(u64, idx_data.len), idx_len);

    const got_idx = try pack_file.readAt(&bind.session, idx_leaf, 0, read_buf[0..idx_data.len]);
    try std.testing.expectEqual(idx_data.len, got_idx);
    try std.testing.expectEqualStrings(idx_data, read_buf[0..idx_data.len]);

    // 6. Test injected Storage vtable
    const storage_vtable = pack_file.storage(&bind.session);
    try storage_vtable.append(storage_vtable.context, pack_leaf, "!");
    const final_len = try storage_vtable.length(storage_vtable.context, pack_leaf);
    try std.testing.expectEqual(@as(u64, chunk1.len + chunk2.len + 1), final_len);

    // 7. Verify illegal paths are rejected
    try std.testing.expectError(error.BadName, pack_file.append(&bind.session, "../escaped.pack", "bad"));
}
