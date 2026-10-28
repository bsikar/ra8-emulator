//! The frame cache (milestone M7): the worker's stored gray frames by
//! position, in a hot RAM tier (the ram-budget table) and a cold tier of
//! one delete-on-close file per segment behind the file-free `Backing`.
//! A segment is a keyframe plus the deltas against it, so a frame rebuilds
//! from its own segment alone. Segments leave oldest-by-position first,
//! whole; a cold tier that fails costs the segment it was to take, never
//! the put, since the cache holds only what replay can rebuild. A
//! regenerate marker is a pixel-free entry that belongs to no segment and
//! is bounded in count. `relieve` drops everything; checkpoint pictures
//! live in the object space and no relief reaches them. The worker puts
//! and the session thread looks up under one mutex; a lookup copies the
//! payload bytes under it and decodes outside.
const std = @import("std");
const types = @import("frame_cache_types.zig");
const frame_types = @import("frame_types.zig");
const frame_rebuild = @import("frame_rebuild.zig");

pub const Position = types.Position;
pub const FrameRecord = frame_types.FrameRecord;
pub const FrameHeader = frame_types.FrameHeader;
pub const Decoded = types.Decoded;
pub const Limits = types.Limits;
pub const File = types.File;
pub const Backing = types.Backing;
pub const Hit = types.Hit;
pub const Report = types.Report;
pub const hotBytesFor = types.hotBytesFor;
pub const Error = frame_rebuild.Error;

const no_segment = types.no_segment;
const Entry = types.Entry;
const Segment = types.Segment;
const Snapshot = types.Snapshot;

pub const FrameCache = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    limits: Limits,
    backing: ?Backing = null,
    mutex: std.Io.Mutex = .init,
    entries: std.ArrayList(Entry) = .empty,
    segments: std.ArrayList(Segment) = .empty,
    next_segment: u32 = 0,
    open_segment: ?u32 = null,
    markers: usize = 0,
    ram_used: u64 = 0,
    disk_used: u64 = 0,
    /// Set when a delta lacks its keyframe or the open segment was
    /// dropped; read it through `wantsKeyframe`.
    need_key: std.atomic.Value(bool) = .init(true),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, limits: Limits, backing: ?Backing) FrameCache {
        return .{ .allocator = allocator, .io = io, .limits = limits, .backing = backing };
    }

    pub fn deinit(self: *FrameCache) void {
        _ = self.dropAll();
        self.entries.deinit(self.allocator);
        self.segments.deinit(self.allocator);
    }

    /// Whether the next frame the tap sends must be a keyframe.
    pub fn wantsKeyframe(self: *const FrameCache) bool {
        return self.need_key.load(.acquire);
    }

    pub fn sink(self: *FrameCache) frame_types.FrameSink {
        return .{ .ctx = self, .writeFrameFn = sinkWrite };
    }

    fn sinkWrite(ctx: *anyopaque, record: *const FrameRecord) anyerror!void {
        const self: *FrameCache = @ptrCast(@alignCast(ctx));
        try self.put(record);
    }

    /// Stores one frame, copying its payload, which must match the
    /// header's length and CRC. A delta without an open keyframe is
    /// refused (NoKeyframe). A cold tier failing while making room drops
    /// the segment it was spilling; the put still succeeds.
    pub fn put(self: *FrameCache, record: *const FrameRecord) !void {
        const header = record.header;
        if (!header.verifyCrc(record.payload)) return frame_types.Error.BadCrc;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        const seg = try self.segmentFor(header);
        var entry: Entry = .{ .header = header, .segment = if (seg) |s| s.id else no_segment };
        if (seg) |s| {
            self.keepPayload(s, &entry, record.payload) catch |err| {
                // A keyframe's segment has no entry yet: leave none behind.
                if (header.kind == .keyframe) _ = self.dropSegment(s.id);
                return err;
            };
            if (entry.payload.len != 0) {
                s.ram += entry.payload.len;
                self.ram_used += entry.payload.len;
            }
        } else self.markers += 1;
        self.insert(entry);
        if (seg == null) self.boundMarkers();
        self.enforce();
    }

    fn segmentFor(self: *FrameCache, header: FrameHeader) !?*Segment {
        switch (header.kind) {
            .delta => {
                const open = self.open_segment orelse return self.refuse();
                return self.segmentById(open) orelse self.refuse();
            },
            .regenerate_by_replay => {
                self.open_segment = null;
                return null;
            },
            .keyframe => {
                try self.segments.append(self.allocator, .{ .id = self.next_segment, .key = header.position });
                self.next_segment += 1;
                const seg = &self.segments.items[self.segments.items.len - 1];
                self.open_segment = seg.id;
                self.need_key.store(false, .release);
                return seg;
            },
        }
    }

    fn refuse(self: *FrameCache) error{NoKeyframe} {
        self.need_key.store(true, .release);
        return error.NoKeyframe;
    }

    fn segmentById(self: *FrameCache, id: u32) ?*Segment {
        for (self.segments.items) |*seg| if (seg.id == id) return seg;
        return null;
    }

    /// Hot: copy into RAM; cold segment: append to its file.
    fn keepPayload(self: *FrameCache, seg: *Segment, entry: *Entry, payload: []const u8) !void {
        if (payload.len == 0) return;
        if (seg.file) |file| {
            try file.vtable.write(file.context, seg.disk_len, payload);
            entry.disk_offset = seg.disk_len;
            seg.disk_len += payload.len;
            self.disk_used += payload.len;
            return;
        }
        entry.payload = try self.allocator.dupe(u8, payload);
    }

    /// Capacity was reserved up front, so this cannot fail.
    fn insert(self: *FrameCache, entry: Entry) void {
        var at = self.entries.items.len;
        while (at > 0 and before(entry.header.position, self.entries.items[at - 1].header.position)) at -= 1;
        self.entries.insertAssumeCapacity(at, entry);
    }

    /// `order` is null only across branches, separated by the test above.
    fn before(a: Position, b: Position) bool {
        if (a.branch != b.branch) return a.branch < b.branch;
        return Position.order(a, b).? == .lt;
    }

    /// Past the cap the oldest markers go.
    fn boundMarkers(self: *FrameCache) void {
        while (self.markers > self.limits.max_markers) {
            for (self.entries.items, 0..) |entry, i| {
                if (entry.segment != no_segment) continue;
                _ = self.entries.orderedRemove(i);
                self.markers -= 1;
                break;
            }
        }
    }

    /// Hot overflow goes cold, cold overflow goes away; never fails.
    fn enforce(self: *FrameCache) void {
        while (self.ram_used > self.limits.ram_bytes) {
            const seg = self.oldest(.hot) orelse break;
            if (self.backing != null and self.limits.disk_bytes > 0) {
                const id = seg.id;
                self.spill(seg) catch {
                    _ = self.dropSegment(id);
                };
            } else {
                _ = self.dropSegment(seg.id);
            }
        }
        while (self.disk_used > self.limits.disk_bytes) {
            const seg = self.oldest(.cold) orelse break;
            _ = self.dropSegment(seg.id);
        }
    }

    /// The hot (or cold) segment whose keyframe sits earliest.
    fn oldest(self: *FrameCache, comptime tier: enum { hot, cold }) ?*Segment {
        var best: ?*Segment = null;
        for (self.segments.items) |*seg| {
            if (tier == .hot and seg.ram == 0) continue;
            if (tier == .cold and seg.file == null) continue;
            if (best == null or before(seg.key, best.?.key)) best = seg;
        }
        return best;
    }

    /// Moves a segment's payloads to a new cold file.
    fn spill(self: *FrameCache, seg: *Segment) !void {
        var name_buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "seg-{x:0>8}", .{seg.id}) catch unreachable;
        const backing = self.backing.?;
        const file = try backing.createFn(backing.context, name);
        errdefer file.vtable.close(file.context);
        var offset: u64 = 0;
        for (self.entries.items) |*entry| {
            if (entry.segment != seg.id or entry.payload.len == 0) continue;
            try file.vtable.write(file.context, offset, entry.payload);
            offset += entry.payload.len;
        }
        offset = 0;
        for (self.entries.items) |*entry| {
            if (entry.segment != seg.id or entry.payload.len == 0) continue;
            entry.disk_offset = offset;
            offset += entry.payload.len;
            self.allocator.free(entry.payload);
            entry.payload = &.{};
        }
        self.ram_used -= seg.ram;
        seg.ram = 0;
        seg.file = file;
        seg.disk_len = offset;
        self.disk_used += offset;
    }

    /// Drops one segment whole: its entries, hot bytes and cold file.
    fn dropSegment(self: *FrameCache, id: u32) Report {
        var report: Report = .{};
        var keep: usize = 0;
        for (self.entries.items) |entry| {
            if (entry.segment != id) {
                self.entries.items[keep] = entry;
                keep += 1;
                continue;
            }
            report.frames += 1;
            report.bytes += entry.payload.len;
            self.allocator.free(entry.payload);
        }
        self.entries.shrinkRetainingCapacity(keep);
        for (self.segments.items, 0..) |*seg, i| {
            if (seg.id != id) continue;
            self.ram_used -= seg.ram;
            self.disk_used -= seg.disk_len;
            report.bytes += seg.disk_len;
            if (seg.file) |file| file.vtable.close(file.context);
            _ = self.segments.orderedRemove(i);
            break;
        }
        if (self.open_segment == id) {
            self.open_segment = null;
            self.need_key.store(true, .release);
        }
        return report;
    }

    /// Everything at once, in one pass over the entries.
    fn dropAll(self: *FrameCache) Report {
        var report: Report = .{ .frames = self.entries.items.len };
        for (self.entries.items) |entry| {
            report.bytes += entry.payload.len;
            self.allocator.free(entry.payload);
        }
        self.entries.clearRetainingCapacity();
        for (self.segments.items) |seg| {
            report.bytes += seg.disk_len;
            if (seg.file) |file| file.vtable.close(file.context);
        }
        self.segments.clearRetainingCapacity();
        self.ram_used = 0;
        self.disk_used = 0;
        self.markers = 0;
        self.open_segment = null;
        self.need_key.store(true, .release);
        return report;
    }

    /// The relief step: drops every frame, hot and cold.
    pub fn relieve(self: *FrameCache) Report {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.dropAll();
    }

    pub fn count(self: *FrameCache) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.entries.items.len;
    }

    pub fn ramBytes(self: *FrameCache) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.ram_used;
    }

    pub fn diskBytes(self: *FrameCache) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.disk_used;
    }

    /// The newest frame at or before `at` on its line.
    pub fn lookup(self: *FrameCache, allocator: std.mem.Allocator, at: Position) !Hit {
        const snap = (try self.snapshot(allocator, at)) orelse return .none;
        if (snap.header.kind == .regenerate_by_replay) {
            return .{ .regenerate = .{ .position = snap.header.position, .virtual_ns = snap.header.virtual_ns } };
        }
        return .{ .frame = try decodeSnapshot(allocator, snap) };
    }

    /// Under the lock: find the frame, copy its payload (and keyframe's).
    fn snapshot(self: *FrameCache, allocator: std.mem.Allocator, at: Position) !?Snapshot {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const index = self.newestAtOrBefore(at) orelse return null;
        const entry = self.entries.items[index];
        if (entry.header.kind == .regenerate_by_replay) return .{ .header = entry.header, .payload = &.{} };
        const own = try self.fetch(allocator, entry);
        errdefer allocator.free(own);
        var key_payload: ?[]u8 = null;
        if (entry.header.kind == .delta) {
            const key_entry = self.keyframeOf(entry.segment) orelse return Error.NoKeyframe;
            key_payload = try self.fetch(allocator, key_entry);
        }
        return .{ .header = entry.header, .payload = own, .key_payload = key_payload };
    }

    fn decodeSnapshot(allocator: std.mem.Allocator, snap: Snapshot) !Decoded {
        defer allocator.free(snap.payload);
        defer if (snap.key_payload) |key| allocator.free(key);
        return frame_rebuild.rebuild(allocator, snap.header, snap.payload, snap.key_payload);
    }

    fn newestAtOrBefore(self: *FrameCache, at: Position) ?usize {
        var lo: usize = 0;
        var hi: usize = self.entries.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (before(at, self.entries.items[mid].header.position)) hi = mid else lo = mid + 1;
        }
        if (lo == 0) return null;
        const found = lo - 1;
        return if (self.entries.items[found].header.position.branch == at.branch) found else null;
    }

    fn keyframeOf(self: *FrameCache, segment: u32) ?Entry {
        for (self.entries.items) |entry| {
            if (entry.segment == segment and entry.header.kind == .keyframe) return entry;
        }
        return null;
    }

    /// A copy of an entry's compressed payload, from RAM or its file.
    fn fetch(self: *FrameCache, allocator: std.mem.Allocator, entry: Entry) ![]u8 {
        const len = entry.header.compressed_len;
        if (entry.payload.len != 0 or len == 0) return allocator.dupe(u8, entry.payload);
        const seg = self.segmentById(entry.segment) orelse return Error.NoKeyframe;
        const file = seg.file orelse return Error.Truncated;
        const out = try allocator.alloc(u8, len);
        errdefer allocator.free(out);
        var got: usize = 0;
        while (got < out.len) {
            const n = try file.vtable.read(file.context, entry.disk_offset + got, out[got..]);
            if (n == 0) return Error.Truncated;
            got += n;
        }
        if (!entry.header.verifyCrc(out)) return Error.BadCrc;
        return out;
    }
};
