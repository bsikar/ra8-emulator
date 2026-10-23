//! Pack file compaction planning and garbage ratio computation.
//!
//! Evaluates pack files against all live object identities reachable across
//! every kept manifest on every branch line, plus pinned bookmarks and pictures.
//! When a pack's dead/garbage bytes exceed 30%, a pure compaction plan is
//! computed specifying which live objects to copy into a new consolidated pack
//! and which packs become obsolete.
const std = @import("std");
const ObjectId = @import("object_id.zig").ObjectId;
const pack_mod = @import("pack.zig");
const pack_index = @import("pack_index.zig");
const manifest_mod = @import("manifest.zig");

pub const trigger_percent: u32 = 30;

pub const LiveSet = std.AutoHashMap([16]u8, void);

pub const LiveObject = struct {
    object_id: ObjectId,
    pack_id: u32,
    pack_offset: u64,
    compressed_len: u32,
    uncompressed_len: u32,
};

pub const PackStats = struct {
    pack_id: u32,
    total_entries: usize,
    live_entries: usize,
    dead_entries: usize,
    total_bytes: u64,
    live_bytes: u64,
    dead_bytes: u64,
    needs_compaction: bool,

    pub fn garbageRatio(self: PackStats) f64 {
        if (self.total_bytes == 0) return 0.0;
        return @as(f64, @floatFromInt(self.dead_bytes)) / @as(f64, @floatFromInt(self.total_bytes));
    }
};

pub const CompactionPlan = struct {
    new_pack_id: u32,
    copy_objects: []LiveObject,
    obsolete_packs: []u32,
    pack_stats: []PackStats,

    pub fn deinit(self: *CompactionPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.copy_objects);
        allocator.free(self.obsolete_packs);
        allocator.free(self.pack_stats);
        self.* = undefined;
    }
};

/// Returns true when dead bytes strictly exceed 30% of total pack bytes.
pub fn shouldCompact(dead_bytes: u64, total_bytes: u64) bool {
    if (total_bytes == 0) return false;
    return (dead_bytes * 100) > (total_bytes * trigger_percent);
}

/// Builds the comprehensive set of live object identities across all manifests
/// from all branches plus pinned bookmark objects and pictures.
pub fn buildLiveSet(
    allocator: std.mem.Allocator,
    manifests: []const *const manifest_mod.Manifest,
    pinned_objects: []const ObjectId,
) !LiveSet {
    var set = LiveSet.init(allocator);
    errdefer set.deinit();

    for (manifests) |m| {
        for (m.pages) |p| {
            try set.put(p.object.bytes, {});
        }
        for (m.blobs) |b| {
            try set.put(b.object.bytes, {});
        }
        if (m.picture) |pic| {
            try set.put(pic.bytes, {});
        }
    }
    for (pinned_objects) |pin| {
        try set.put(pin.bytes, {});
    }
    return set;
}

/// Analyzes an individual pack index against the live set.
pub fn inspectPack(pack: pack_index.Index, live_set: *const LiveSet) PackStats {
    var live_entries: usize = 0;
    var dead_entries: usize = 0;
    var live_bytes: u64 = 0;
    var dead_bytes: u64 = 0;

    for (pack.entries) |entry| {
        const item_bytes = @as(u64, entry.compressed_len) + pack_mod.record_overhead;
        if (live_set.contains(entry.object_id.bytes)) {
            live_entries += 1;
            live_bytes += item_bytes;
        } else {
            dead_entries += 1;
            dead_bytes += item_bytes;
        }
    }

    const total_bytes = live_bytes + dead_bytes;
    return .{
        .pack_id = pack.pack_id,
        .total_entries = pack.entries.len,
        .live_entries = live_entries,
        .dead_entries = dead_entries,
        .total_bytes = total_bytes,
        .live_bytes = live_bytes,
        .dead_bytes = dead_bytes,
        .needs_compaction = shouldCompact(dead_bytes, total_bytes),
    };
}

/// Computes the compaction plan across all provided pack indexes.
pub fn planCompaction(
    allocator: std.mem.Allocator,
    packs: []const pack_index.Index,
    live_set: *const LiveSet,
    new_pack_id: u32,
) !CompactionPlan {
    const stats_slice = try allocator.alloc(PackStats, packs.len);
    errdefer allocator.free(stats_slice);

    var obsolete_count: usize = 0;
    var live_to_copy_count: usize = 0;

    for (packs, 0..) |pack, i| {
        stats_slice[i] = inspectPack(pack, live_set);
        if (stats_slice[i].needs_compaction) {
            obsolete_count += 1;
            live_to_copy_count += stats_slice[i].live_entries;
        }
    }

    const obsolete_packs = try allocator.alloc(u32, obsolete_count);
    errdefer allocator.free(obsolete_packs);

    const copy_objects = try allocator.alloc(LiveObject, live_to_copy_count);
    errdefer allocator.free(copy_objects);

    var obs_idx: usize = 0;
    var copy_idx: usize = 0;

    for (packs, 0..) |pack, i| {
        if (!stats_slice[i].needs_compaction) continue;

        obsolete_packs[obs_idx] = pack.pack_id;
        obs_idx += 1;

        for (pack.entries) |entry| {
            if (live_set.contains(entry.object_id.bytes)) {
                copy_objects[copy_idx] = .{
                    .object_id = entry.object_id,
                    .pack_id = pack.pack_id,
                    .pack_offset = entry.pack_offset,
                    .compressed_len = entry.compressed_len,
                    .uncompressed_len = entry.uncompressed_len,
                };
                copy_idx += 1;
            }
        }
    }

    return .{
        .new_pack_id = new_pack_id,
        .copy_objects = copy_objects,
        .obsolete_packs = obsolete_packs,
        .pack_stats = stats_slice,
    };
}
