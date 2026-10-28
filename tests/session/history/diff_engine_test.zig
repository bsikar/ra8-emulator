//! Tests for state diff engine (Slice 23.5).
const std = @import("std");
const ra8 = @import("ra8");
const diff_mod = ra8.session.history_diff_engine;
const manifest_mod = ra8.session.history_manifest;
const ObjectId = ra8.session.history_object_id.ObjectId;
const Position = ra8.session.history_position.Position;
const file = ra8.board.snapshot.run.file;

test "diffCoreRegs detects register changes" {
    var r_a = diff_mod.CoreRegs{ .present = true };
    r_a.values[0] = 0x1234; // r0
    r_a.values[15] = 0x08000100; // pc

    var r_b = diff_mod.CoreRegs{ .present = true };
    r_b.values[0] = 0x5678; // r0 modified
    r_b.values[1] = 0x42; // r1 modified
    r_b.values[15] = 0x08000100; // pc unchanged

    const diffs = try diff_mod.diffCoreRegs(std.testing.allocator, r_a, r_b);
    defer std.testing.allocator.free(diffs);

    try std.testing.expectEqual(@as(usize, 2), diffs.len);
    try std.testing.expectEqualStrings("r0", diffs[0].name);
    try std.testing.expectEqual(@as(u32, 0x1234), diffs[0].val_a);
    try std.testing.expectEqual(@as(u32, 0x5678), diffs[0].val_b);

    try std.testing.expectEqualStrings("r1", diffs[1].name);
    try std.testing.expectEqual(@as(u32, 0), diffs[1].val_a);
    try std.testing.expectEqual(@as(u32, 0x42), diffs[1].val_b);
}

test "diffPages computes modified 4 KiB memory pages with guest addresses" {
    const obj_zero = ObjectId{ .bytes = @splat(0) };
    const obj_one = ObjectId{ .bytes = @splat(1) };
    const obj_two = ObjectId{ .bytes = @splat(2) };

    const pages_a = [_]manifest_mod.PageRef{
        .{ .space = .cpu0_sram, .page_index = 0, .object = obj_zero },
        .{ .space = .cpu0_sram, .page_index = 1, .object = obj_one },
        .{ .space = .cpu0_dtcm, .page_index = 0, .object = obj_zero },
    };

    const pages_b = [_]manifest_mod.PageRef{
        .{ .space = .cpu0_sram, .page_index = 0, .object = obj_zero }, // unchanged
        .{ .space = .cpu0_sram, .page_index = 1, .object = obj_two }, // modified
        .{ .space = .cpu0_sram, .page_index = 2, .object = obj_one }, // added
    };

    var sorted_a = pages_a;
    std.mem.sort(manifest_mod.PageRef, &sorted_a, {}, pageRefLessThan);
    var sorted_b = pages_b;
    std.mem.sort(manifest_mod.PageRef, &sorted_b, {}, pageRefLessThan);

    const pos = Position{ .branch = 0, .r = 0, .phase = .cpu0, .o = 0, .gap = .retired };
    const m_a = manifest_mod.Manifest{
        .position = pos,
        .checkpoint_id = 1,
        .pages = &sorted_a,
        .blobs = &.{},
        .root_hash = obj_zero,
    };
    const m_b = manifest_mod.Manifest{
        .position = pos,
        .checkpoint_id = 2,
        .pages = &sorted_b,
        .blobs = &.{},
        .root_hash = obj_one,
    };

    const p_diffs = try diff_mod.diffPages(std.testing.allocator, &m_a, &m_b);
    defer std.testing.allocator.free(p_diffs);

    // Expecting 3 page diffs: dtcm page 0 (deleted/missing in B), sram page 1 (modified), sram page 2 (added)
    try std.testing.expectEqual(@as(usize, 3), p_diffs.len);

    // Check guest addresses
    for (p_diffs) |pd| {
        const base = diff_mod.spaceBaseAddress(pd.space).?;
        try std.testing.expectEqual(base + pd.page_index * 4096, pd.address);
    }
}

fn pageRefLessThan(_: void, a: manifest_mod.PageRef, b: manifest_mod.PageRef) bool {
    return manifest_mod.pageOrder(a, b) == .lt;
}

test "diffPeripherals computes delta on changed sections" {
    // Build dummy snapshot A with timers section
    var f_a: std.Io.Writer.Allocating = try .initCapacity(std.testing.allocator, 128);
    defer f_a.deinit();
    try file.writeHeader(&f_a.writer);
    const timers_a = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 };
    try file.writeSectionHeader(&f_a.writer, .timers, timers_a.len);
    try f_a.writer.writeAll(&timers_a);

    // Build dummy snapshot B with timers section changed at offset 4
    var f_b: std.Io.Writer.Allocating = try .initCapacity(std.testing.allocator, 128);
    defer f_b.deinit();
    try file.writeHeader(&f_b.writer);
    const timers_b = [_]u8{ 0, 1, 2, 3, 0xFF, 5, 6, 7 };
    try file.writeSectionHeader(&f_b.writer, .timers, timers_b.len);
    try f_b.writer.writeAll(&timers_b);

    const deltas = try diff_mod.diffPeripherals(std.testing.allocator, f_a.written(), f_b.written());
    defer std.testing.allocator.free(deltas);

    try std.testing.expectEqual(@as(usize, 1), deltas.len);
    try std.testing.expectEqualStrings("timers", deltas[0].unit);
    try std.testing.expectEqual(file.Kind.timers, deltas[0].kind);
    try std.testing.expectEqual(@as(u32, 4), deltas[0].offset);
    try std.testing.expectEqual(@as(u32, 1), deltas[0].changed_bytes);
}

test "diffManifests full integration" {
    const obj_zero = ObjectId{ .bytes = @splat(0) };
    const pos = Position{ .branch = 0, .r = 10, .phase = .cpu0, .o = 1, .gap = .retired };

    const m = manifest_mod.Manifest{
        .position = pos,
        .checkpoint_id = 1,
        .pages = &.{},
        .blobs = &.{},
        .root_hash = obj_zero,
    };

    var res = try diff_mod.diffManifests(std.testing.allocator, null, &m, null, null);
    defer res.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 10), res.pos_b.r);
    try std.testing.expectEqual(@as(usize, 0), res.pages.len);
    try std.testing.expectEqual(@as(usize, 0), res.cpu0_regs.len);
}
