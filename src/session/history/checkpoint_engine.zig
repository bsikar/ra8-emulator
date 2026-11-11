//! Content-addressed checkpoint engine.
//!
//! Produces Merkle manifests capturing machine state. Clean pages reuse
//! previous manifest identities without rehashing or disk I/O; dirty pages
//! are hashed and deduplicated across spaces and time before being emitted
//! to an injected object sink.
const std = @import("std");
const manifest_mod = @import("manifest.zig");
pub const ObjectId = @import("object_id.zig").ObjectId;
const Position = @import("position.zig").Position;
const DirtyPages = @import("dirty_pages.zig").DirtyPages;
const SpaceMap = @import("dirty_pages.zig").SpaceMap;
const page_size = @import("dirty_pages.zig").page_size;
const Touched = @import("touched_pages.zig").Touched;
const snap_state = @import("../root.zig").board.state;
const Files = snap_state.Files;
const inc_restore = @import("incremental_restore.zig");
const getSpaceSlice = inc_restore.getSpaceSlice;
const SpaceAccessor = inc_restore.SpaceAccessor;

const zero_page_bytes: [page_size]u8 = @splat(0);

pub const SpaceSpan = struct {
    space: manifest_mod.SpaceId,
    bytes: []const u8,
    sdram_resident: ?*const @import("ra8_chip").core.cpu.memory.store.SdramSet = null,
};

pub const BlobSpan = struct {
    space: manifest_mod.SpaceId,
    bytes: []const u8,
};

pub const ObjectSink = struct {
    context: *anyopaque,
    putFn: *const fn (context: *anyopaque, id: ObjectId, bytes: []const u8) anyerror!void,

    pub fn put(self: ObjectSink, id: ObjectId, bytes: []const u8) anyerror!void {
        return self.putFn(self.context, id, bytes);
    }
};

pub const CaptureStats = struct {
    pages_hashed: usize = 0,
    pages_reused: usize = 0,
    objects_stored: usize = 0,
};

pub const CaptureResult = struct {
    manifest: manifest_mod.Manifest,
    stats: CaptureStats,
};

const DirtyCoord = struct {
    space: manifest_mod.SpaceId,
    page_index: u32,
};

pub const CheckpointEngine = struct {
    allocator: std.mem.Allocator,
    seen_objects: std.AutoHashMap([16]u8, void),
    registered_root: ?ObjectId = null,
    last_stats: CaptureStats = .{},
    /// The pages written between the previous capture and the last one,
    /// null after a first capture. The engine owns it; `takeTouched` hands
    /// it to whoever keeps it beside the manifest.
    last_touched: ?Touched = null,

    pub fn init(allocator: std.mem.Allocator) CheckpointEngine {
        return .{ .allocator = allocator, .seen_objects = std.AutoHashMap([16]u8, void).init(allocator) };
    }

    pub fn deinit(self: *CheckpointEngine) void {
        self.dropTouched();
        self.seen_objects.deinit();
        self.* = undefined;
    }

    pub fn reset(self: *CheckpointEngine) void {
        self.seen_objects.clearRetainingCapacity();
        self.registered_root = null;
        self.last_stats = .{};
        self.dropTouched();
    }

    fn dropTouched(self: *CheckpointEngine) void {
        if (self.last_touched) |*held| held.deinit();
        self.last_touched = null;
    }

    /// Transfers the last capture's touched-page record to the caller,
    /// who owns it and must deinit it.
    pub fn takeTouched(self: *CheckpointEngine) ?Touched {
        const held = self.last_touched;
        self.last_touched = null;
        return held;
    }

    pub fn registerManifest(self: *CheckpointEngine, manifest: *const manifest_mod.Manifest) !void {
        var last_page: ?ObjectId = null;
        for (manifest.pages) |page| {
            if (last_page) |prev| if (prev.eql(page.object)) continue;
            last_page = page.object;
            try self.seen_objects.put(page.object.bytes, {});
        }
        for (manifest.blobs) |blob| try self.seen_objects.put(blob.object.bytes, {});
        self.registered_root = manifest.root_hash;
    }

    fn storeObject(
        self: *CheckpointEngine,
        id: ObjectId,
        bytes: []const u8,
        sink: ?ObjectSink,
        stats: *CaptureStats,
    ) !void {
        const gop = try self.seen_objects.getOrPut(id.bytes);
        if (!gop.found_existing) {
            if (sink) |s| {
                try s.put(id, bytes);
            }
            stats.objects_stored += 1;
        }
    }

    fn resolvePage(
        self: *CheckpointEngine,
        dirty: *const DirtyPages,
        dirty_clears: *std.ArrayList(DirtyCoord),
        prev_manifest: ?*const manifest_mod.Manifest,
        prev_pages: []const manifest_mod.PageRef,
        prev_cursor: *usize,
        span: SpaceSpan,
        p_idx: usize,
        zero_id: ?ObjectId,
        sink: ?ObjectSink,
        stats: *CaptureStats,
    ) !ObjectId {
        const is_dirty = if (prev_manifest != null) dirty.isDirty(span.space, @intCast(p_idx)) else true;
        if (!is_dirty and prev_manifest != null) {
            if (prev_cursor.* < prev_pages.len) {
                const cur = prev_pages[prev_cursor.*];
                if (cur.space == span.space and cur.page_index == @as(u32, @intCast(p_idx))) {
                    prev_cursor.* += 1;
                    stats.pages_reused += 1;
                    return cur.object;
                }
            }
            if (findPage(prev_pages, span.space, @intCast(p_idx))) |obj| {
                stats.pages_reused += 1;
                return obj;
            }
        }
        if (prev_manifest != null) {
            try dirty_clears.append(self.allocator, .{ .space = span.space, .page_index = @intCast(p_idx) });
        }
        const start = p_idx * page_size;
        const end = @min(span.bytes.len, start + page_size);
        if (zero_id != null and end - start == page_size) if (span.sdram_resident) |res| {
            if (p_idx < res.capacity() and !res.isSet(p_idx)) {
                try self.storeObject(zero_id.?, &zero_page_bytes, sink, stats);
                stats.pages_hashed += 1;
                return zero_id.?;
            }
        };
        const page_data = span.bytes[start..end];
        const id = if (zero_id != null and page_data.len == page_size and inc_restore.isZeroPage(page_data))
            zero_id.?
        else
            ObjectId.compute(page_data);
        try self.storeObject(id, page_data, sink, stats);
        stats.pages_hashed += 1;
        return id;
    }

    fn collectPages(
        self: *CheckpointEngine,
        dirty: *const DirtyPages,
        dirty_clears: *std.ArrayList(DirtyCoord),
        prev_manifest: ?*const manifest_mod.Manifest,
        spaces: []const SpaceSpan,
        sink: ?ObjectSink,
        stats: *CaptureStats,
    ) ![]manifest_mod.PageRef {
        var total_pages: usize = 0;
        var ordered = true;
        var last_space: ?u8 = null;
        for (spaces) |span| {
            total_pages += (span.bytes.len + page_size - 1) / page_size;
            const sid = @backingInt(span.space);
            if (last_space) |prev| if (sid <= prev) {
                ordered = false;
            };
            last_space = sid;
        }
        const page_refs = try self.allocator.alloc(manifest_mod.PageRef, total_pages);
        errdefer self.allocator.free(page_refs);
        const zero_id: ?ObjectId = if (prev_manifest == null) ObjectId.compute(&zero_page_bytes) else null;
        const prev_pages = if (prev_manifest) |prev| prev.pages else &[_]manifest_mod.PageRef{};
        var prev_cursor: usize = 0;
        var out_idx: usize = 0;
        for (spaces) |span| {
            const count = (span.bytes.len + page_size - 1) / page_size;
            const s_idx = SpaceMap.indexOf(span.space);
            var p_idx: usize = 0;
            while (p_idx < count) {
                if (prev_manifest != null and (p_idx & 63) == 0 and p_idx + 64 <= count and s_idx != null) {
                    const w_idx = p_idx >> 6;
                    const mask = if (w_idx < dirty.masks[s_idx.?].len) dirty.masks[s_idx.?][w_idx] else 0;
                    if (mask == 0 and prev_cursor + 64 <= prev_pages.len and
                        prev_pages[prev_cursor].space == span.space and prev_pages[prev_cursor].page_index == @as(u32, @intCast(p_idx)) and
                        prev_pages[prev_cursor + 63].space == span.space and prev_pages[prev_cursor + 63].page_index == @as(u32, @intCast(p_idx + 63)))
                    {
                        @memcpy(page_refs[out_idx..][0..64], prev_pages[prev_cursor..][0..64]);
                        prev_cursor += 64;
                        out_idx += 64;
                        stats.pages_reused += 64;
                        p_idx += 64;
                        continue;
                    }
                }
                const obj_id = try self.resolvePage(dirty, dirty_clears, prev_manifest, prev_pages, &prev_cursor, span, p_idx, zero_id, sink, stats);
                page_refs[out_idx] = .{ .space = span.space, .page_index = @intCast(p_idx), .object = obj_id };
                out_idx += 1;
                p_idx += 1;
            }
        }
        if (!ordered and !std.sort.isSorted(manifest_mod.PageRef, page_refs, {}, pageLessThan)) {
            std.mem.sort(manifest_mod.PageRef, page_refs, {}, pageLessThan);
        }
        return page_refs;
    }

    fn collectBlobs(
        self: *CheckpointEngine,
        blobs: []const BlobSpan,
        sink: ?ObjectSink,
        stats: *CaptureStats,
    ) ![]manifest_mod.BlobRef {
        const blob_refs = try self.allocator.alloc(manifest_mod.BlobRef, blobs.len);
        errdefer self.allocator.free(blob_refs);

        for (blobs, 0..) |blob, i| {
            const id = ObjectId.compute(blob.bytes);
            try self.storeObject(id, blob.bytes, sink, stats);
            blob_refs[i] = .{
                .space = blob.space,
                .object = id,
                .size = @intCast(blob.bytes.len),
            };
        }

        std.mem.sort(manifest_mod.BlobRef, blob_refs, {}, blobLessThan);
        return blob_refs;
    }

    pub fn capture(
        self: *CheckpointEngine,
        dirty: *DirtyPages,
        prev_manifest: ?*const manifest_mod.Manifest,
        pos: Position,
        checkpoint_id: u32,
        picture: ?ObjectId,
        spaces: []const SpaceSpan,
        blobs: []const BlobSpan,
        sink: ?ObjectSink,
    ) !CaptureResult {
        if (prev_manifest) |prev| {
            const same = if (self.registered_root) |r| r.eql(prev.root_hash) else false;
            if (!same) try self.registerManifest(prev);
        }
        var stats: CaptureStats = .{};
        var dirty_clears: std.ArrayList(DirtyCoord) = .empty;
        defer dirty_clears.deinit(self.allocator);
        const pages = try self.collectPages(dirty, &dirty_clears, prev_manifest, spaces, sink, &stats);
        errdefer self.allocator.free(pages);
        const blob_refs = try self.collectBlobs(blobs, sink, &stats);
        errdefer self.allocator.free(blob_refs);
        const root = manifest_mod.computeMerkleRoot(pos, checkpoint_id, picture, pages, blob_refs);
        // The write record for the interval since the previous capture,
        // copied before the bits clear.
        var touched: ?Touched = if (prev_manifest) |prev|
            try Touched.fromDirty(self.allocator, prev.checkpoint_id, dirty)
        else
            null;
        errdefer if (touched) |*t| t.deinit();
        // Atomic dirty clearing: only upon full capture success
        if (prev_manifest == null) {
            dirty.clearAll();
        } else {
            for (dirty_clears.items) |coord| dirty.clearDirty(coord.space, coord.page_index);
        }
        self.registered_root = root;
        self.last_stats = stats;
        self.dropTouched();
        self.last_touched = touched;
        touched = null;
        return .{
            .manifest = .{
                .position = pos,
                .checkpoint_id = checkpoint_id,
                .picture = picture,
                .pages = pages,
                .blobs = blob_refs,
                .root_hash = root,
            },
            .stats = stats,
        };
    }

    pub fn captureFromFiles(
        self: *CheckpointEngine,
        files: *Files,
        dirty: *DirtyPages,
        prev_manifest: ?*const manifest_mod.Manifest,
        pos: Position,
        checkpoint_id: u32,
        picture: ?ObjectId,
        sink: ?ObjectSink,
        accessor: ?SpaceAccessor,
    ) !CaptureResult {
        var full_snap: std.Io.Writer.Allocating = try .initCapacity(self.allocator, 1024);
        defer full_snap.deinit();
        try files.writeParts(&full_snap.writer, .{ .memory = false });
        return self.captureFromFilesWithRunState(files, dirty, prev_manifest, pos, checkpoint_id, picture, full_snap.written(), sink, accessor);
    }

    pub fn captureFromFilesWithRunState(
        self: *CheckpointEngine,
        files: *Files,
        dirty: *DirtyPages,
        prev_manifest: ?*const manifest_mod.Manifest,
        pos: Position,
        checkpoint_id: u32,
        picture: ?ObjectId,
        run_state: []const u8,
        sink: ?ObjectSink,
        accessor: ?SpaceAccessor,
    ) !CaptureResult {
        var spans: [12]SpaceSpan = undefined;
        var count: usize = 0;
        const tracked_spaces = [_]manifest_mod.SpaceId{
            .cpu0_mram,   .cpu0_dtcm, .cpu0_sram, .cpu0_sdram,
            .cpu0_ppb,    .cpu1_mram, .cpu1_dtcm, .cpu1_ppb,
            .store_extra, .nor_flash, .sd_card,   .eink_buffer,
        };
        const res = if (accessor == null and files.store.owns_port and files.store.sdram_demand_zero) files.store.sdramResident() else null;
        for (tracked_spaces) |space| {
            if (getSpaceSlice(files, space, accessor)) |slice| {
                spans[count] = .{ .space = space, .bytes = slice, .sdram_resident = if (space == .cpu0_sdram and slice.len <= 128 * 1024 * 1024) res else null };
                count += 1;
            }
        }
        const blob_spans = [_]BlobSpan{.{ .space = .run_state, .bytes = run_state }};
        return self.capture(dirty, prev_manifest, pos, checkpoint_id, picture, spans[0..count], &blob_spans, sink);
    }
};

pub fn findPage(pages: []const manifest_mod.PageRef, space: manifest_mod.SpaceId, page_index: u32) ?ObjectId {
    var low: usize = 0;
    var high: usize = pages.len;
    const target_space = @backingInt(space);
    while (low < high) {
        const mid = low + (high - low) / 2;
        const mid_item = pages[mid];
        const item_space = @backingInt(mid_item.space);
        if (target_space < item_space) {
            high = mid;
        } else if (target_space > item_space) {
            low = mid + 1;
        } else if (page_index < mid_item.page_index) {
            high = mid;
        } else if (page_index > mid_item.page_index) {
            low = mid + 1;
        } else {
            return mid_item.object;
        }
    }
    return null;
}

fn pageLessThan(_: void, a: manifest_mod.PageRef, b: manifest_mod.PageRef) bool {
    const sa = @backingInt(a.space);
    const sb = @backingInt(b.space);
    if (sa != sb) return sa < sb;
    return a.page_index < b.page_index;
}

fn blobLessThan(_: void, a: manifest_mod.BlobRef, b: manifest_mod.BlobRef) bool {
    const sa = @backingInt(a.space);
    const sb = @backingInt(b.space);
    if (sa != sb) return sa < sb;
    return std.mem.order(u8, &a.object.bytes, &b.object.bytes) == .lt;
}
