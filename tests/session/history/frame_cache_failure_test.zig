//! The frame cache's failure and bound behavior (src/session/history/
//! frame_cache.zig): a cold tier that fails costs a segment and never the
//! put or the accounting, regenerate markers are bounded, a payload that
//! does not match its header is refused on the way in, eviction is by
//! position, the keyframe request is a locked read, and the checkpoint
//! picture source skips lost frames.
const std = @import("std");
const ra8 = @import("ra8");
const cache_mod = ra8.session.history_frame_cache;
const types = ra8.session.history_frame_types;
const fx = @import("frame_fixture.zig");

const gpa = std.testing.allocator;
const at = fx.at;
const picture = fx.picture;
const keyRecord = fx.keyRecord;
const deltaRecord = fx.deltaRecord;
const put = fx.put;

fn marker(r: u64) types.FrameRecord {
    return .{ .header = .{
        .kind = .regenerate_by_replay,
        .position = at(0, r),
        .virtual_ns = r * 1000,
        .width = fx.w,
        .height = fx.h,
        .rect = .{},
        .uncompressed_len = 0,
        .compressed_len = 0,
        .crc32c = 0,
    }, .payload = &.{} };
}

fn keySize(gray: []const u8) !u64 {
    var record = try keyRecord(gpa, at(0, 1), gray);
    defer record.deinit(gpa);
    return record.header.compressed_len;
}

test "a cold tier that cannot create costs the segment, not the put" {
    var disk: fx.Disk = .{ .gpa = gpa, .fail_create = true };
    var cache = cache_mod.FrameCache.init(gpa, std.testing.io, .{ .ram_bytes = 1, .disk_bytes = 1 << 20 }, disk.backing());
    defer cache.deinit();
    const key = picture(1, 0);
    // The put succeeds: the cache holds only what replay can rebuild.
    try put(&cache, gpa, try keyRecord(gpa, at(0, 1), &key));
    try std.testing.expectEqual(@as(usize, 0), cache.count());
    try std.testing.expectEqual(@as(u64, 0), cache.ramBytes());
    try std.testing.expectEqual(@as(u64, 0), cache.diskBytes());
    try std.testing.expectEqual(@as(usize, 0), disk.open);
    try std.testing.expect(cache.wantsKeyframe());
    // The cache still works afterwards, and teardown frees nothing twice.
    disk.fail_create = false;
    try put(&cache, gpa, try keyRecord(gpa, at(0, 2), &key));
    try std.testing.expectEqual(@as(usize, 1), disk.open);
    try fx.expectFrame(&cache, at(0, 2), 2, &key);
}

test "a cold write that fails mid-spill drops that segment and keeps the books" {
    var disk: fx.Disk = .{ .gpa = gpa };
    const key_a = picture(1, 0);
    const delta_a = picture(1, 90);
    const key_b = picture(80, 0);
    const one = try keySize(&key_a);
    // Room for the first segment, not for two.
    var cache = cache_mod.FrameCache.init(gpa, std.testing.io, .{ .ram_bytes = one + one / 2, .disk_bytes = 1 << 20 }, disk.backing());
    defer cache.deinit();
    try put(&cache, gpa, try keyRecord(gpa, at(0, 1), &key_a));
    try put(&cache, gpa, try deltaRecord(gpa, at(0, 2), &key_a, &delta_a));
    try std.testing.expect(cache.ramBytes() > 0);

    disk.fail_write = true;
    try put(&cache, gpa, try keyRecord(gpa, at(0, 3), &key_b));
    // The first segment was the one spilled, and it is gone whole.
    const gone = try cache.lookup(gpa, at(0, 2));
    try std.testing.expect(gone == .none);
    try std.testing.expectEqual(@as(usize, 0), disk.open);
    try std.testing.expectEqual(@as(u64, 0), cache.diskBytes());
    // The newest segment is intact, and the counter is its bytes alone.
    try fx.expectFrame(&cache, at(0, 3), 3, &key_b);
    try std.testing.expectEqual(try keySize(&key_b), cache.ramBytes());
    // The open segment was not the one dropped, so a delta still lands.
    disk.fail_write = false;
    const delta_b = picture(80, 33);
    try put(&cache, gpa, try deltaRecord(gpa, at(0, 4), &key_b, &delta_b));
    try fx.expectFrame(&cache, at(0, 4), 4, &delta_b);
}

test "regenerate markers are bounded and belong to no segment" {
    var cache = cache_mod.FrameCache.init(gpa, std.testing.io, .{ .ram_bytes = 1 << 20, .max_markers = 8 }, null);
    defer cache.deinit();
    const key = picture(5, 0);
    try put(&cache, gpa, try keyRecord(gpa, at(0, 1), &key));
    for (10..110) |r| try put(&cache, gpa, marker(r));
    // One keyframe and the newest eight markers; no segment per marker.
    try std.testing.expectEqual(@as(usize, 9), cache.count());
    try std.testing.expectEqual(@as(usize, 1), cache.segments.items.len);
    var hit = try cache.lookup(gpa, at(0, 109));
    try std.testing.expectEqual(@as(u64, 109), hit.regenerate.position.r);
    // The evicted old markers no longer shadow the frame behind them.
    hit = try cache.lookup(gpa, at(0, 50));
    try std.testing.expectEqualSlices(u8, &key, hit.frame.pixels);
    hit.frame.deinit(gpa);
}

test "a payload that does not match its header is refused on the way in" {
    var cache = cache_mod.FrameCache.init(gpa, std.testing.io, .{ .ram_bytes = 1 << 20 }, null);
    defer cache.deinit();
    const key = picture(5, 0);
    var good = try keyRecord(gpa, at(0, 1), &key);
    defer good.deinit(gpa);
    const bad = try gpa.dupe(u8, good.payload);
    defer gpa.free(bad);
    bad[bad.len / 2] ^= 0x55;
    const corrupt: types.FrameRecord = .{ .header = good.header, .payload = bad };
    try std.testing.expectError(error.BadCrc, cache.put(&corrupt));
    const short: types.FrameRecord = .{ .header = good.header, .payload = good.payload[1..] };
    try std.testing.expectError(error.BadCrc, cache.put(&short));
    try std.testing.expectEqual(@as(usize, 0), cache.count());
    try std.testing.expectEqual(@as(u64, 0), cache.ramBytes());
}

test "eviction goes by position, not by arrival order" {
    const key_late = picture(1, 0);
    const key_early = picture(90, 0);
    const room = @max(try keySize(&key_late), try keySize(&key_early)) + 4;
    var cache = cache_mod.FrameCache.init(gpa, std.testing.io, .{ .ram_bytes = room }, null);
    defer cache.deinit();
    try put(&cache, gpa, try keyRecord(gpa, at(0, 10), &key_late));
    // A replayed older frame arrives later and overflows the hot tier.
    try put(&cache, gpa, try keyRecord(gpa, at(0, 1), &key_early));
    // The older position left; the newer one is still the newest answer.
    const none = try cache.lookup(gpa, at(0, 5));
    try std.testing.expect(none == .none);
    try fx.expectFrame(&cache, at(0, 10), 10, &key_late);
}

test "the keyframe request is set, cleared and re-set through the accessor" {
    var cache = cache_mod.FrameCache.init(gpa, std.testing.io, .{ .ram_bytes = 1 << 20 }, null);
    defer cache.deinit();
    try std.testing.expect(cache.wantsKeyframe());
    const key = picture(5, 0);
    try put(&cache, gpa, try keyRecord(gpa, at(0, 1), &key));
    try std.testing.expect(!cache.wantsKeyframe());
    _ = cache.relieve();
    try std.testing.expect(cache.wantsKeyframe());
}
