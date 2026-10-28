//! Tests for CheckpointEngine dirty tracking, clean page reuse, deduplication, and Merkle stability.
const std = @import("std");
const ra8 = @import("ra8");
const CheckpointEngine = ra8.session.history_checkpoint_engine.CheckpointEngine;
const SpaceSpan = ra8.session.history_checkpoint_engine.SpaceSpan;
const ObjectSink = ra8.session.history_checkpoint_engine.ObjectSink;
const DirtyPages = ra8.session.history_dirty_pages.DirtyPages;
const Position = ra8.session.history_position.Position;
const ObjectId = ra8.session.history_object_id.ObjectId;
const memmap = ra8.chip.core.memmap;

const CountingSink = struct {
    stored: std.AutoHashMap([16]u8, usize),

    pub fn init(allocator: std.mem.Allocator) CountingSink {
        return .{ .stored = std.AutoHashMap([16]u8, usize).init(allocator) };
    }

    pub fn deinit(self: *CountingSink) void {
        self.stored.deinit();
    }

    pub fn sink(self: *CountingSink) ObjectSink {
        return .{ .context = self, .putFn = &putImpl };
    }

    fn putImpl(ctx: *anyopaque, id: ObjectId, bytes: []const u8) anyerror!void {
        _ = bytes;
        const self: *CountingSink = @ptrCast(@alignCast(ctx));
        const res = try self.stored.getOrPut(id.bytes);
        if (res.found_existing) {
            res.value_ptr.* += 1;
        } else {
            res.value_ptr.* = 1;
        }
    }
};

test "CheckpointEngine unchanged machine produces zero hashed pages and identical Merkle root" {
    const allocator = std.testing.allocator;
    var dirty = try DirtyPages.init(allocator);
    defer dirty.deinit();

    var engine = CheckpointEngine.init(allocator);
    defer engine.deinit();

    var mram_buf: [4 * 4096]u8 = undefined;
    @memset(&mram_buf, 0x11);
    var sram_buf: [4 * 4096]u8 = undefined;
    @memset(&sram_buf, 0x22);

    const spaces = [_]SpaceSpan{
        .{ .space = .cpu0_mram, .bytes = &mram_buf },
        .{ .space = .cpu0_sram, .bytes = &sram_buf },
    };
    const pos = Position{ .r = 10, .phase = .cpu0 };

    var sink_tracker = CountingSink.init(allocator);
    defer sink_tracker.deinit();

    var res1 = try engine.capture(&dirty, null, pos, 1, null, &spaces, &.{}, sink_tracker.sink());
    defer res1.manifest.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 8), res1.stats.pages_hashed);
    try std.testing.expectEqual(@as(usize, 0), res1.stats.pages_reused);

    var res2 = try engine.capture(&dirty, &res1.manifest, pos, 1, null, &spaces, &.{}, sink_tracker.sink());
    defer res2.manifest.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), res2.stats.pages_hashed);
    try std.testing.expectEqual(@as(usize, 8), res2.stats.pages_reused);
    try std.testing.expectEqual(@as(usize, 0), res2.stats.objects_stored);
    try std.testing.expect(res2.manifest.root_hash.eql(res1.manifest.root_hash));
}

test "CheckpointEngine one dirty page hashes exactly one page" {
    const allocator = std.testing.allocator;
    var dirty = try DirtyPages.init(allocator);
    defer dirty.deinit();

    var engine = CheckpointEngine.init(allocator);
    defer engine.deinit();

    var mram_buf: [4 * 4096]u8 = undefined;
    @memset(&mram_buf, 0xAA);
    var sram_buf: [4 * 4096]u8 = undefined;
    @memset(&sram_buf, 0xBB);

    const spaces = [_]SpaceSpan{
        .{ .space = .cpu0_mram, .bytes = &mram_buf },
        .{ .space = .cpu0_sram, .bytes = &sram_buf },
    };
    const pos = Position{ .r = 20, .phase = .cpu0 };

    var res1 = try engine.capture(&dirty, null, pos, 1, null, &spaces, &.{}, null);
    defer res1.manifest.deinit(allocator);

    mram_buf[2 * 4096 + 50] ^= 0x55;
    dirty.markDirty(.cpu0_mram, 2);

    var res2 = try engine.capture(&dirty, &res1.manifest, pos, 2, null, &spaces, &.{}, null);
    defer res2.manifest.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), res2.stats.pages_hashed);
    try std.testing.expectEqual(@as(usize, 7), res2.stats.pages_reused);
    try std.testing.expect(!res2.manifest.root_hash.eql(res1.manifest.root_hash));
}

test "CheckpointEngine identical pages across spaces deduplicate to one object" {
    const allocator = std.testing.allocator;
    var dirty = try DirtyPages.init(allocator);
    defer dirty.deinit();

    var engine = CheckpointEngine.init(allocator);
    defer engine.deinit();

    var sink_tracker = CountingSink.init(allocator);
    defer sink_tracker.deinit();

    var mram_buf: [2 * 4096]u8 = undefined;
    var dtcm_buf: [2 * 4096]u8 = undefined;
    @memset(mram_buf[0..4096], 0x77);
    @memset(dtcm_buf[0..4096], 0x77);
    @memset(mram_buf[4096..8192], 0x88);
    @memset(dtcm_buf[4096..8192], 0x99);

    const spaces = [_]SpaceSpan{
        .{ .space = .cpu0_mram, .bytes = &mram_buf },
        .{ .space = .cpu0_dtcm, .bytes = &dtcm_buf },
    };
    const pos = Position{ .r = 30, .phase = .cpu0 };

    var res = try engine.capture(&dirty, null, pos, 1, null, &spaces, &.{}, sink_tracker.sink());
    defer res.manifest.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), res.stats.pages_hashed);
    try std.testing.expectEqual(@as(usize, 3), res.stats.objects_stored);
    try std.testing.expectEqual(@as(usize, 3), sink_tracker.stored.count());
}

test "CheckpointEngine incremental manifest matches from-scratch after writes and barrier" {
    const allocator = std.testing.allocator;
    var dirty_incr = try DirtyPages.init(allocator);
    defer dirty_incr.deinit();
    var dirty_scratch = try DirtyPages.init(allocator);
    defer dirty_scratch.deinit();

    var engine_incr = CheckpointEngine.init(allocator);
    defer engine_incr.deinit();
    var engine_scratch = CheckpointEngine.init(allocator);
    defer engine_scratch.deinit();

    var mram: [4 * 4096]u8 = undefined;
    @memset(&mram, 0x12);
    var sram: [4 * 4096]u8 = undefined;
    @memset(&sram, 0x34);

    const spaces = [_]SpaceSpan{
        .{ .space = .cpu0_mram, .bytes = &mram },
        .{ .space = .cpu0_sram, .bytes = &sram },
    };
    const pos1 = Position{ .r = 40, .phase = .cpu0 };

    var base = try engine_incr.capture(&dirty_incr, null, pos1, 1, null, &spaces, &.{}, null);
    defer base.manifest.deinit(allocator);

    const obs = dirty_incr.storeObserver();
    var pre: [8]u8 = @splat(0);
    mram[0 * 4096 + 10] = 0xAA;
    obs.bytes(.{ .base = memmap.mram_base, .offset = 10, .initiator = .cpu0, .pre = &pre });

    sram[3 * 4096 + 20] = 0xBB;
    obs.bytes(.{ .base = memmap.sram_base, .offset = 3 * 4096 + 20, .initiator = .cpu0, .pre = &pre });

    const pos2 = Position{ .r = 41, .phase = .cpu0 };
    var m_incr1 = try engine_incr.capture(&dirty_incr, &base.manifest, pos2, 2, null, &spaces, &.{}, null);
    defer m_incr1.manifest.deinit(allocator);

    var m_scratch1 = try engine_scratch.capture(&dirty_scratch, null, pos2, 2, null, &spaces, &.{}, null);
    defer m_scratch1.manifest.deinit(allocator);

    try std.testing.expect(m_incr1.manifest.root_hash.eql(m_scratch1.manifest.root_hash));
    for (m_incr1.manifest.pages, 0..) |p, i| {
        try std.testing.expect(p.eql(m_scratch1.manifest.pages[i]));
    }

    obs.barrier(.wipe);
    mram[1 * 4096 + 5] = 0xCC;

    const pos3 = Position{ .r = 42, .phase = .cpu0 };
    var m_incr2 = try engine_incr.capture(&dirty_incr, &m_incr1.manifest, pos3, 3, null, &spaces, &.{}, null);
    defer m_incr2.manifest.deinit(allocator);

    var m_scratch2 = try engine_scratch.capture(&dirty_scratch, null, pos3, 3, null, &spaces, &.{}, null);
    defer m_scratch2.manifest.deinit(allocator);

    try std.testing.expect(m_incr2.manifest.root_hash.eql(m_scratch2.manifest.root_hash));
    for (m_incr2.manifest.pages, 0..) |p, i| {
        try std.testing.expect(p.eql(m_scratch2.manifest.pages[i]));
    }
}

const FailingSink = struct {
    fail_on_count: usize,
    count: usize = 0,

    pub fn sink(self: *FailingSink) ObjectSink {
        return .{ .context = self, .putFn = &putImpl };
    }

    fn putImpl(ctx: *anyopaque, id: ObjectId, bytes: []const u8) anyerror!void {
        _ = id;
        _ = bytes;
        const self: *FailingSink = @ptrCast(@alignCast(ctx));
        self.count += 1;
        if (self.count >= self.fail_on_count) return error.DiskFull;
    }
};

test "CheckpointEngine atomic dirty clearing preserves dirty bits on capture failure" {
    const allocator = std.testing.allocator;
    var dirty = try DirtyPages.init(allocator);
    defer dirty.deinit();

    var engine = CheckpointEngine.init(allocator);
    defer engine.deinit();

    var mram_buf: [2 * 4096]u8 = undefined;
    @memset(&mram_buf, 0x11);

    const spaces = [_]SpaceSpan{
        .{ .space = .cpu0_mram, .bytes = &mram_buf },
    };
    const pos = Position{ .r = 10, .phase = .cpu0 };

    var res1 = try engine.capture(&dirty, null, pos, 1, null, &spaces, &.{}, null);
    defer res1.manifest.deinit(allocator);

    mram_buf[10] ^= 0x55;
    mram_buf[4096 + 10] ^= 0xAA;
    dirty.markDirty(.cpu0_mram, 0);
    dirty.markDirty(.cpu0_mram, 1);

    var failing = FailingSink{ .fail_on_count = 1 };
    const err = engine.capture(&dirty, &res1.manifest, pos, 2, null, &spaces, &.{}, failing.sink());
    try std.testing.expectError(error.DiskFull, err);

    try std.testing.expect(dirty.isDirty(.cpu0_mram, 0));
    try std.testing.expect(dirty.isDirty(.cpu0_mram, 1));
}

test "CheckpointEngine records the pages written since the previous capture" {
    const allocator = std.testing.allocator;
    var dirty = try DirtyPages.init(allocator);
    defer dirty.deinit();
    var engine = CheckpointEngine.init(allocator);
    defer engine.deinit();

    var mram_buf: [4 * 4096]u8 = undefined;
    @memset(&mram_buf, 0x11);
    const spaces = [_]SpaceSpan{.{ .space = .cpu0_mram, .bytes = &mram_buf }};
    const pos = Position{ .r = 10, .phase = .cpu0 };

    var res1 = try engine.capture(&dirty, null, pos, 1, null, &spaces, &.{}, null);
    defer res1.manifest.deinit(allocator);
    // A first capture has no earlier interval: no record.
    try std.testing.expect(engine.takeTouched() == null);

    // An unchanged write still marks its page.
    dirty.markDirty(.cpu0_mram, 2);
    var res2 = try engine.capture(&dirty, &res1.manifest, pos, 2, null, &spaces, &.{}, null);
    defer res2.manifest.deinit(allocator);
    var touched = engine.takeTouched().?;
    defer touched.deinit();
    try std.testing.expectEqual(@as(u32, 1), touched.since);
    try std.testing.expect(touched.isTouched(.{ .space = .cpu0_mram, .page_index = 2 }));
    try std.testing.expect(!touched.isTouched(.{ .space = .cpu0_mram, .page_index = 1 }));

    // The next interval starts clean.
    var res3 = try engine.capture(&dirty, &res2.manifest, pos, 3, null, &spaces, &.{}, null);
    defer res3.manifest.deinit(allocator);
    var quiet = engine.takeTouched().?;
    defer quiet.deinit();
    try std.testing.expectEqual(@as(u32, 2), quiet.since);
    try std.testing.expect(!quiet.isTouched(.{ .space = .cpu0_mram, .page_index = 2 }));
}
