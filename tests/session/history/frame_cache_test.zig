//! Covers src/session/history/frame_cache.zig: newest-frame-at-or-before
//! lookup, bit-exact rebuild from a segment's own keyframe, hot-tier
//! overflow going cold and still reading back, cold-tier overflow dropping
//! the oldest segment whole, regenerate markers, the keyframe-first rule,
//! relief dropping everything including cold files, and a worker thread
//! putting while the session thread looks up.
const std = @import("std");
const ra8 = @import("ra8");
const cache_mod = ra8.session.history_frame_cache;
const types = ra8.session.history_frame_types;
const crop = ra8.session.history_frame_crop;
const pic = ra8.session.history_checkpoint_picture;
const fx = @import("frame_fixture.zig");

const w = fx.w;
const h = fx.h;
const px_count = fx.px_count;
const at = fx.at;
const picture = fx.picture;
const keyRecord = fx.keyRecord;
const deltaRecord = fx.deltaRecord;
const put = fx.put;
const Disk = fx.Disk;
const expectFrame = fx.expectFrame;

test "the hot tier follows the ram budget table" {
    const mib: u64 = 1024 * 1024;
    try std.testing.expectEqual(256 * mib, cache_mod.hotBytesFor(1024 * mib));
    try std.testing.expectEqual(256 * mib, cache_mod.hotBytesFor(4096 * mib));
    try std.testing.expectEqual(128 * mib, cache_mod.hotBytesFor(512 * mib));
    try std.testing.expectEqual(48 * mib, cache_mod.hotBytesFor(256 * mib));
    try std.testing.expectEqual(@as(u64, 0), cache_mod.hotBytesFor(128 * mib));
}

test "lookup answers the newest frame at or before the position, bit-exact" {
    const gpa = std.testing.allocator;
    var cache = cache_mod.FrameCache.init(gpa, std.testing.io, .{ .ram_bytes = 1 << 20 }, null);
    defer cache.deinit();
    const key = picture(10, 0);
    const one = picture(10, 200);
    const two = picture(10, 90);
    try put(&cache, gpa, try keyRecord(gpa, at(0, 1), &key));
    try put(&cache, gpa, try deltaRecord(gpa, at(0, 2), &key, &one));
    try put(&cache, gpa, try deltaRecord(gpa, at(0, 4), &key, &two));

    try expectFrame(&cache, at(0, 1), 1, &key);
    try expectFrame(&cache, at(0, 2), 2, &one);
    try expectFrame(&cache, .{ .branch = 0, .r = 3, .phase = .board, .o = 1 }, 2, &one);
    try expectFrame(&cache, at(0, 4), 4, &two);
    try expectFrame(&cache, at(0, 900), 4, &two);

    var none = try cache.lookup(gpa, at(0, 0));
    try std.testing.expect(none == .none);
    // Another line has no frames here.
    none = try cache.lookup(gpa, at(1, 900));
    try std.testing.expect(none == .none);
}

test "frames put out of order are still found by position" {
    const gpa = std.testing.allocator;
    var cache = cache_mod.FrameCache.init(gpa, std.testing.io, .{ .ram_bytes = 1 << 20 }, null);
    defer cache.deinit();
    const key = picture(3, 0);
    const late = picture(3, 70);
    try put(&cache, gpa, try keyRecord(gpa, at(0, 5), &key));
    try put(&cache, gpa, try deltaRecord(gpa, at(0, 9), &key, &late));
    try put(&cache, gpa, try deltaRecord(gpa, at(0, 7), &key, &key));
    try expectFrame(&cache, at(0, 8), 7, &key);
    try expectFrame(&cache, at(0, 10), 9, &late);
}

test "a hot overflow goes cold and still reads back, and cold segments take appends" {
    const gpa = std.testing.allocator;
    var disk: Disk = .{ .gpa = gpa };
    var cache = cache_mod.FrameCache.init(gpa, std.testing.io, .{ .ram_bytes = 1, .disk_bytes = 1 << 20 }, disk.backing());
    defer cache.deinit();

    const key_a = picture(1, 0);
    const a1 = picture(1, 111);
    const key_b = picture(50, 0);
    const b1 = picture(50, 222);
    try put(&cache, gpa, try keyRecord(gpa, at(0, 1), &key_a));
    // The open segment's keyframe alone overflows the 1 byte budget: it is cold now.
    try std.testing.expectEqual(@as(u64, 0), cache.ramBytes());
    try std.testing.expect(cache.diskBytes() > 0);
    // A delta of a cold segment is appended to its file.
    try put(&cache, gpa, try deltaRecord(gpa, at(0, 2), &key_a, &a1));
    try put(&cache, gpa, try keyRecord(gpa, at(0, 3), &key_b));
    try put(&cache, gpa, try deltaRecord(gpa, at(0, 4), &key_b, &b1));
    try std.testing.expectEqual(@as(usize, 2), disk.open);
    try std.testing.expectEqual(@as(u64, 0), cache.ramBytes());

    // Segment isolation: each delta rebuilds against its own keyframe.
    try expectFrame(&cache, at(0, 2), 2, &a1);
    try expectFrame(&cache, at(0, 4), 4, &b1);
    try expectFrame(&cache, at(0, 3), 3, &key_b);
    try expectFrame(&cache, at(0, 1), 1, &key_a);
}

test "a full cold tier drops the oldest segment whole and nothing else" {
    const gpa = std.testing.allocator;
    var disk: Disk = .{ .gpa = gpa };
    const probe_key = picture(1, 0);
    const probe = try keyRecord(gpa, at(0, 1), &probe_key);
    var sized = probe;
    defer sized.deinit(gpa);
    const one_key: u64 = sized.header.compressed_len;
    // Room for a bit over two keyframes' worth of cold bytes.
    var cache = cache_mod.FrameCache.init(gpa, std.testing.io, .{ .ram_bytes = 0, .disk_bytes = one_key * 5 / 2 }, disk.backing());
    defer cache.deinit();

    const keys = [_][px_count]u8{ picture(1, 0), picture(60, 0), picture(120, 0) };
    for (&keys, 0..) |*key, i| try put(&cache, gpa, try keyRecord(gpa, at(0, i + 1), key));
    // The three segments are three keyframes; only the oldest went.
    try std.testing.expectEqual(@as(usize, 2), cache.count());
    try std.testing.expectEqual(@as(usize, 2), disk.open);
    const gone = try cache.lookup(gpa, at(0, 1));
    try std.testing.expect(gone == .none);
    try expectFrame(&cache, at(0, 2), 2, &keys[1]);
    try expectFrame(&cache, at(0, 3), 3, &keys[2]);
}

test "no cold tier and no hot room keeps nothing, and asks for a keyframe" {
    const gpa = std.testing.allocator;
    var cache = cache_mod.FrameCache.init(gpa, std.testing.io, .{ .ram_bytes = 0 }, null);
    defer cache.deinit();
    const key = picture(9, 0);
    try put(&cache, gpa, try keyRecord(gpa, at(0, 1), &key));
    try std.testing.expectEqual(@as(usize, 0), cache.count());
    try std.testing.expect(cache.wantsKeyframe());
}

test "a regenerate marker is answered, and a delta needs its keyframe" {
    const gpa = std.testing.allocator;
    var cache = cache_mod.FrameCache.init(gpa, std.testing.io, .{ .ram_bytes = 1 << 20 }, null);
    defer cache.deinit();
    const key = picture(5, 0);
    const now = picture(5, 33);
    try std.testing.expectError(error.NoKeyframe, put(&cache, gpa, try deltaRecord(gpa, at(0, 1), &key, &now)));
    try std.testing.expect(cache.wantsKeyframe());

    try put(&cache, gpa, try keyRecord(gpa, at(0, 2), &key));
    try std.testing.expect(!cache.wantsKeyframe());
    var marker: types.FrameRecord = .{ .header = .{
        .kind = .regenerate_by_replay,
        .position = at(0, 6),
        .virtual_ns = 6000,
        .width = w,
        .height = h,
        .rect = .{},
        .uncompressed_len = 0,
        .compressed_len = 0,
        .crc32c = 0,
    }, .payload = &.{} };
    try cache.put(&marker);
    var hit = try cache.lookup(gpa, at(0, 7));
    try std.testing.expectEqual(@as(u64, 6), hit.regenerate.position.r);
    try std.testing.expectEqual(@as(u64, 6000), hit.regenerate.virtual_ns);
    // The marker closed the segment: a delta after it has no keyframe.
    try std.testing.expectError(error.NoKeyframe, put(&cache, gpa, try deltaRecord(gpa, at(0, 8), &key, &now)));
    // The frame before the marker is untouched.
    hit = try cache.lookup(gpa, at(0, 5));
    try std.testing.expectEqualSlices(u8, &key, hit.frame.pixels);
    hit.frame.deinit(gpa);
}

test "relief drops the whole cache, hot and cold, and closes every cold file" {
    const gpa = std.testing.allocator;
    var disk: Disk = .{ .gpa = gpa };
    var cache = cache_mod.FrameCache.init(gpa, std.testing.io, .{ .ram_bytes = 1, .disk_bytes = 1 << 20 }, disk.backing());
    defer cache.deinit();
    const key = picture(2, 0);
    const key2 = picture(70, 0);
    try put(&cache, gpa, try keyRecord(gpa, at(0, 1), &key));
    try put(&cache, gpa, try keyRecord(gpa, at(0, 2), &key2));
    try std.testing.expect(disk.open > 0);

    const report = cache.relieve();
    try std.testing.expectEqual(@as(usize, 2), report.frames);
    try std.testing.expect(report.bytes > 0);
    try std.testing.expectEqual(@as(usize, 0), cache.count());
    try std.testing.expectEqual(@as(usize, 0), disk.open);
    try std.testing.expectEqual(@as(u64, 0), cache.ramBytes());
    try std.testing.expectEqual(@as(u64, 0), cache.diskBytes());
    try std.testing.expect(cache.wantsKeyframe());
}

const Producer = struct {
    cache: *cache_mod.FrameCache,
    gpa: std.mem.Allocator,
    failed: bool = false,

    fn run(self: *Producer) void {
        const key = picture(4, 0);
        const sink = self.cache.sink();
        var record = keyRecord(self.gpa, at(0, 1), &key) catch {
            self.failed = true;
            return;
        };
        defer record.deinit(self.gpa);
        sink.writeFrame(&record) catch {
            self.failed = true;
            return;
        };
        for (2..60) |r| {
            const now = picture(4, @intCast(r));
            var delta = deltaRecord(self.gpa, at(0, r), &key, &now) catch {
                self.failed = true;
                return;
            };
            defer delta.deinit(self.gpa);
            sink.writeFrame(&delta) catch {
                self.failed = true;
                return;
            };
        }
    }
};

test "a worker thread puts while the session thread looks up" {
    const gpa = std.testing.allocator;
    var cache = cache_mod.FrameCache.init(gpa, std.testing.io, .{ .ram_bytes = 1 << 20 }, null);
    defer cache.deinit();
    var producer: Producer = .{ .cache = &cache, .gpa = gpa };
    const thread = try std.Thread.spawn(.{}, Producer.run, .{&producer});
    var seen: usize = 0;
    while (seen < 200) : (seen += 1) {
        var hit = try cache.lookup(gpa, at(0, 1000));
        switch (hit) {
            .frame => |*frame| {
                frame.deinit(gpa);
                break;
            },
            else => {},
        }
    }
    thread.join();
    try std.testing.expect(!producer.failed);
    try std.testing.expectEqual(@as(usize, 59), cache.count());
    const final = picture(4, 59);
    try expectFrame(&cache, at(0, 1000), 59, &final);
}
