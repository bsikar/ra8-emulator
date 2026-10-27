//! Covers src/session/history/temp_checkpoints.zig: slow segment splitting
//! (> 250 ms) at 100 ms intervals, hot checkpoint storage in RAM, and nearest
//! prior position / virtual_ns lookup.
const std = @import("std");
const ra8 = @import("ra8");
const temp_cp = ra8.session.history_temp_checkpoints;

test "segment duration threshold identifies slow segments (> 250 ms)" {
    const ms = std.time.ns_per_ms;
    try std.testing.expect(!temp_cp.isSlow(0));
    try std.testing.expect(!temp_cp.isSlow(100 * ms));
    try std.testing.expect(!temp_cp.isSlow(250 * ms));
    try std.testing.expect(temp_cp.isSlow(250 * ms + 1));
    try std.testing.expect(temp_cp.isSlow(500 * ms));
    try std.testing.expect(temp_cp.isSlow(1000 * ms));
}

test "planSplit returns empty for segments <= 250 ms" {
    const gpa = std.testing.allocator;
    const ms = std.time.ns_per_ms;

    const short_plan = try temp_cp.TempCheckpoints.planSplit(gpa, 0, 200 * ms);
    defer gpa.free(short_plan);
    try std.testing.expectEqual(@as(usize, 0), short_plan.len);

    const boundary_plan = try temp_cp.TempCheckpoints.planSplit(gpa, 100 * ms, 350 * ms);
    defer gpa.free(boundary_plan);
    try std.testing.expectEqual(@as(usize, 0), boundary_plan.len);
}

test "planSplit lays checkpoints at 100 ms intervals for segments > 250 ms" {
    const gpa = std.testing.allocator;
    const ms = std.time.ns_per_ms;

    // 500 ms segment from 1000 ms to 1500 ms:
    // target intervals: 1100 ms, 1200 ms, 1300 ms, 1400 ms
    const plan = try temp_cp.TempCheckpoints.planSplit(gpa, 1000 * ms, 1500 * ms);
    defer gpa.free(plan);
    try std.testing.expectEqual(@as(usize, 4), plan.len);
    try std.testing.expectEqual(1100 * ms, plan[0]);
    try std.testing.expectEqual(1200 * ms, plan[1]);
    try std.testing.expectEqual(1300 * ms, plan[2]);
    try std.testing.expectEqual(1400 * ms, plan[3]);
}

test "temporary checkpoints store and query by virtual_ns and position" {
    const gpa = std.testing.allocator;
    var store = temp_cp.TempCheckpoints.init(gpa);
    defer store.deinit();

    const data1 = "snapshot-state-1";
    const data2 = "snapshot-state-2";
    const data3 = "snapshot-state-3";

    try store.add(.{ .branch = 0, .r = 100, .phase = .board, .o = 0 }, 100_000, data1);
    try store.add(.{ .branch = 0, .r = 200, .phase = .board, .o = 0 }, 200_000, data2);
    try store.add(.{ .branch = 0, .r = 300, .phase = .board, .o = 0 }, 300_000, data3);

    try std.testing.expectEqual(@as(usize, 3), store.count());

    // Lookup by virtual_ns
    const hit1 = store.nearestAtOrBeforeNs(150_000);
    try std.testing.expect(hit1 != null);
    try std.testing.expectEqual(@as(u64, 100_000), hit1.?.virtual_ns);
    try std.testing.expectEqualStrings(data1, hit1.?.bytes);

    const hit2 = store.nearestAtOrBeforeNs(200_000);
    try std.testing.expect(hit2 != null);
    try std.testing.expectEqual(@as(u64, 200_000), hit2.?.virtual_ns);
    try std.testing.expectEqualStrings(data2, hit2.?.bytes);

    const hit3 = store.nearestAtOrBeforeNs(50_000);
    try std.testing.expect(hit3 == null);

    // Lookup by Position
    const pos_hit = store.nearestAtOrBefore(.{ .branch = 0, .r = 250, .phase = .board, .o = 0 });
    try std.testing.expect(pos_hit != null);
    try std.testing.expectEqual(@as(u64, 200_000), pos_hit.?.virtual_ns);

    // Clearing releases entries
    store.clear();
    try std.testing.expectEqual(@as(usize, 0), store.count());
    try std.testing.expect(store.nearestAtOrBeforeNs(200_000) == null);
}
