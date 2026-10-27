//! Tests for src/session/history/late_marker.zig (Slice 22.4).
//! Covers late-armed marker indexing, on-disk caching, and count invariance.
const std = @import("std");
const ra8 = @import("ra8");
const late_marker = ra8.session.history_late_marker;
const nav_index = ra8.session.history_nav_index;
const scheduler = ra8.chip.core.scheduler;

const Pos = scheduler.Position;

fn pos(branch: u32, r: u64) Pos {
    return .{ .branch = branch, .r = r, .phase = .cpu0, .o = 0, .gap = .retired };
}

const MemFile = struct {
    allocator: std.mem.Allocator,
    data: std.ArrayListUnmanaged(u8) = .empty,

    fn read(ctx: *anyopaque, offset: u64, buffer: []u8) anyerror!usize {
        const self: *MemFile = @ptrCast(@alignCast(ctx));
        if (offset >= self.data.items.len) return 0;
        const available = self.data.items.len - @as(usize, @intCast(offset));
        const to_read = @min(buffer.len, available);
        @memcpy(buffer[0..to_read], self.data.items[@intCast(offset)..][0..to_read]);
        return to_read;
    }

    fn write(ctx: *anyopaque, offset: u64, bytes: []const u8) anyerror!void {
        const self: *MemFile = @ptrCast(@alignCast(ctx));
        const needed = @as(usize, @intCast(offset)) + bytes.len;
        if (needed > self.data.items.len) {
            try self.data.resize(self.allocator, needed);
        }
        @memcpy(self.data.items[@intCast(offset)..][0..bytes.len], bytes);
    }

    fn close(_: *anyopaque) void {}

    const vtable = late_marker.File.Vtable{
        .read = read,
        .write = write,
        .close = close,
    };

    fn asFile(self: *MemFile) late_marker.File {
        return .{ .context = self, .vtable = &vtable };
    }
};

const MemStorage = struct {
    allocator: std.mem.Allocator,
    file: ?*MemFile = null,

    fn open(ctx: *anyopaque, _: []const u8) anyerror!late_marker.File {
        const self: *MemStorage = @ptrCast(@alignCast(ctx));
        const f = self.file orelse return error.NotFound;
        return f.asFile();
    }

    fn create(ctx: *anyopaque, _: []const u8) anyerror!late_marker.File {
        const self: *MemStorage = @ptrCast(@alignCast(ctx));
        if (self.file == null) {
            self.file = try self.allocator.create(MemFile);
            self.file.?.* = .{ .allocator = self.allocator };
        } else {
            self.file.?.data.clearRetainingCapacity();
        }
        return self.file.?.asFile();
    }

    const vtable = late_marker.Storage.Vtable{
        .open = open,
        .create = create,
    };

    fn asStorage(self: *MemStorage) late_marker.Storage {
        return .{ .context = self, .vtable = &vtable };
    }

    fn deinit(self: *MemStorage) void {
        if (self.file) |f| {
            f.data.deinit(self.allocator);
            self.allocator.destroy(f);
        }
    }
};

test "late marker indexing matches on-time armed marker counts and positions" {
    const allocator = std.testing.allocator;
    var mem_storage = MemStorage{ .allocator = allocator };
    defer mem_storage.deinit();

    const expected_hits = [_]Pos{
        pos(0, 10),
        pos(0, 25),
        pos(0, 42),
    };

    // On-time armed marker simulation:
    var on_time_nav = nav_index.NavIndex.init(allocator);
    defer on_time_nav.deinit();
    for (expected_hits) |p| {
        _ = try on_time_nav.addMarkerArrival("loop_head", 0x0800_2000, p);
    }

    // Late marker indexed by simulated replay and cached:
    var late_nav = nav_index.NavIndex.init(allocator);
    defer late_nav.deinit();

    try late_marker.indexLateMarker(
        allocator,
        mem_storage.asStorage(),
        "markers.idx",
        "loop_head",
        0x0800_2000,
        &expected_hits,
        &late_nav,
    );

    // Verify identical count and position invariance
    for (1..4) |nth| {
        const on_time_pos = on_time_nav.getMarkerArrival("loop_head", nth).?;
        const late_pos = late_nav.getMarkerArrival("loop_head", nth).?;
        try std.testing.expectEqual(on_time_pos, late_pos);
    }

    // Second index lookup should read directly from disk cache:
    var cached_nav = nav_index.NavIndex.init(allocator);
    defer cached_nav.deinit();

    try late_marker.indexLateMarker(
        allocator,
        mem_storage.asStorage(),
        "markers.idx",
        "loop_head",
        0x0800_2000,
        &.{}, // empty hits list to prove cache was loaded
        &cached_nav,
    );

    for (1..4) |nth| {
        const cached_pos = cached_nav.getMarkerArrival("loop_head", nth).?;
        try std.testing.expectEqual(expected_hits[nth - 1], cached_pos);
    }
}

test "indexing a new late marker must not truncate previously cached markers on disk" {
    const allocator = std.testing.allocator;
    var mem_storage = MemStorage{ .allocator = allocator };
    defer mem_storage.deinit();

    const head_hits = [_]Pos{ pos(0, 100), pos(0, 200) };
    const tail_hits = [_]Pos{ pos(0, 150), pos(0, 250), pos(0, 350) };

    var nav1 = nav_index.NavIndex.init(allocator);
    defer nav1.deinit();

    // 1. Index first marker "mark_head"
    try late_marker.indexLateMarker(
        allocator,
        mem_storage.asStorage(),
        "markers.idx",
        "mark_head",
        0x0800_1000,
        &head_hits,
        &nav1,
    );

    // 2. Index second marker "mark_tail"
    try late_marker.indexLateMarker(
        allocator,
        mem_storage.asStorage(),
        "markers.idx",
        "mark_tail",
        0x0800_2000,
        &tail_hits,
        &nav1,
    );

    // 3. In a fresh NavIndex with empty replay hits, query "mark_head" from disk cache
    var nav_head = nav_index.NavIndex.init(allocator);
    defer nav_head.deinit();

    try late_marker.indexLateMarker(
        allocator,
        mem_storage.asStorage(),
        "markers.idx",
        "mark_head",
        0x0800_1000,
        &.{},
        &nav_head,
    );
    try std.testing.expectEqual(head_hits[0], nav_head.getMarkerArrival("mark_head", 1).?);
    try std.testing.expectEqual(head_hits[1], nav_head.getMarkerArrival("mark_head", 2).?);

    // 4. In another fresh NavIndex with empty replay hits, query "mark_tail" from disk cache
    var nav_tail = nav_index.NavIndex.init(allocator);
    defer nav_tail.deinit();

    try late_marker.indexLateMarker(
        allocator,
        mem_storage.asStorage(),
        "markers.idx",
        "mark_tail",
        0x0800_2000,
        &.{},
        &nav_tail,
    );
    try std.testing.expectEqual(tail_hits[0], nav_tail.getMarkerArrival("mark_tail", 1).?);
    try std.testing.expectEqual(tail_hits[1], nav_tail.getMarkerArrival("mark_tail", 2).?);
    try std.testing.expectEqual(tail_hits[2], nav_tail.getMarkerArrival("mark_tail", 3).?);
}

const CountingReplay = struct {
    runs: u32 = 0,
    hits: []const Pos,

    fn run(ctx: *anyopaque, allocator: std.mem.Allocator, _: u32, out: *std.ArrayListUnmanaged(Pos)) anyerror!void {
        const self: *CountingReplay = @ptrCast(@alignCast(ctx));
        self.runs += 1;
        try out.appendSlice(allocator, self.hits);
    }
};

test "armLate replays once and a cached marker is fed back without a replay" {
    const allocator = std.testing.allocator;
    var mem_storage = MemStorage{ .allocator = allocator };
    defer mem_storage.deinit();
    var replay = CountingReplay{ .hits = &.{ pos(0, 10), pos(0, 20) } };

    var first = nav_index.NavIndex.init(allocator);
    defer first.deinit();
    const count = try late_marker.armLate(allocator, mem_storage.asStorage(), "markers.idx", "m", 0x100, .{ .context = &replay, .runFn = &CountingReplay.run }, &first);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(u32, 1), replay.runs);
    try std.testing.expectEqual(@as(usize, 2), first.markerArrivalCount("m"));

    var second = nav_index.NavIndex.init(allocator);
    defer second.deinit();
    try late_marker.loadInto(allocator, mem_storage.asStorage(), "markers.idx", &second);
    try std.testing.expectEqual(pos(0, 20), second.getMarkerArrival("m", 2).?);

    var third = nav_index.NavIndex.init(allocator);
    defer third.deinit();
    _ = try late_marker.armLate(allocator, mem_storage.asStorage(), "markers.idx", "m", 0x100, .{ .context = &replay, .runFn = &CountingReplay.run }, &third);
    try std.testing.expectEqual(@as(u32, 1), replay.runs);
    try std.testing.expectEqual(@as(usize, 2), third.markerArrivalCount("m"));
}
