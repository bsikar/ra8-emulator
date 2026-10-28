//! A disk history's pack store: the page and blob objects the checkpoint
//! engine emits, kept in append-only `pack-N.pack` files with a sorted
//! `pack-N.idx` beside each, instead of one loose file per 4 KiB page.
//!
//! Objects put during a checkpoint wait in memory and reach disk when the
//! recorder syncs its object space: the pack is appended and synced first,
//! then the index is written atomically, so a crash leaves either the whole
//! pack indexed or a pack the next open re-indexes from its bytes. A pack
//! file is never changed once sealed; compaction writes a new pack of the
//! live objects and only then removes the packs it replaces.
const std = @import("std");
const history = @import("ra8_host").history;
const pack_file = history.pack_file;
const session_pack = @import("ra8_session").history_pack;
const pack_index = @import("ra8_session").history_pack_index;
const compaction = @import("ra8_session").history_compaction;
const ObjectId = @import("ra8_session").history_object_id.ObjectId;

pub const Report = struct {
    packs_removed: usize = 0,
    objects_copied: usize = 0,
    bytes_before: u64 = 0,
    bytes_after: u64 = 0,
};

pub const PackStore = struct {
    gpa: std.mem.Allocator,
    store: history.storage.Store,
    bytes: pack_file.Storage,
    sealed: std.ArrayList(pack_index.Index) = .empty,
    next_id: u32 = 1,
    /// The pack being built: header, then one record per pending object.
    building: std.ArrayList(u8) = .empty,
    entries: std.ArrayList(pack_index.Entry) = .empty,

    /// Opens the store over `session`'s object space, loading every sealed
    /// pack's index and rebuilding one that is missing or damaged.
    pub fn open(gpa: std.mem.Allocator, session: *history.session.Session) !*PackStore {
        const self = try gpa.create(PackStore);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .store = history.storage.Store.from(session), .bytes = pack_file.storage(session) };
        errdefer self.close();
        var names: Names = .{ .gpa = gpa };
        defer names.deinit();
        try self.store.vtable.list(self.store.context, .objects, .{ .context = &names, .visit = &Names.visit });
        for (names.packs.items) |id| try self.load(id);
        return self;
    }

    /// Writes any pending objects and frees the store.
    pub fn close(self: *PackStore) void {
        self.seal() catch {};
        for (self.sealed.items) |*index| index.deinit(self.gpa);
        self.sealed.deinit(self.gpa);
        self.building.deinit(self.gpa);
        self.entries.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Whether the object is held, sealed or waiting.
    pub fn has(self: *const PackStore, id: ObjectId) bool {
        for (self.entries.items) |entry| if (entry.object_id.eql(id)) return true;
        for (self.sealed.items) |*index| if (index.lookup(id) != null) return true;
        return false;
    }

    /// Queues one object for the next seal; one already held is a no-op.
    pub fn put(self: *PackStore, id: ObjectId, data: []const u8) !void {
        if (self.has(id)) return;
        if (self.building.items.len == 0) {
            var w: std.Io.Writer.Allocating = .fromArrayList(self.gpa, &self.building);
            defer self.building = w.toArrayList();
            try session_pack.writeHeader(&w.writer, self.next_id);
        }
        const offset = self.building.items.len;
        var w: std.Io.Writer.Allocating = .fromArrayList(self.gpa, &self.building);
        defer self.building = w.toArrayList();
        const total = try session_pack.encodeRecord(self.gpa, &w.writer, id, session_pack.flags.page, data);
        try self.entries.append(self.gpa, .{
            .object_id = id,
            .xxh3_prefilter = id.prefilter(),
            .pack_offset = offset,
            .compressed_len = @intCast(total - session_pack.record_overhead),
            .uncompressed_len = @intCast(data.len),
        });
    }

    /// Makes the pending objects durable: the pack first, then its index.
    pub fn seal(self: *PackStore) !void {
        if (self.entries.items.len == 0) return;
        var leaf: [32]u8 = undefined;
        const pack_leaf = try packName(&leaf, self.next_id, "pack");
        try self.bytes.append(self.bytes.context, pack_leaf, self.building.items);
        try self.bytes.sync(self.bytes.context, pack_leaf);
        try self.writeIndex(self.next_id, self.entries.items);
        const owned = try self.gpa.dupe(pack_index.Entry, self.entries.items);
        errdefer self.gpa.free(owned);
        std.mem.sort(pack_index.Entry, owned, {}, pack_index.Entry.order);
        try self.sealed.append(self.gpa, .{ .pack_id = self.next_id, .entries = owned });
        self.next_id += 1;
        self.building.clearRetainingCapacity();
        self.entries.clearRetainingCapacity();
    }

    /// The bytes of the object, read from its pack or the waiting buffer;
    /// null when the store does not hold it. The caller owns the bytes.
    pub fn get(self: *PackStore, allocator: std.mem.Allocator, id: ObjectId) !?[]u8 {
        for (self.entries.items) |entry| if (entry.object_id.eql(id)) return try self.decode(allocator, self.building.items[@intCast(entry.pack_offset)..]);
        for (self.sealed.items) |*index| {
            const entry = index.lookup(id) orelse continue;
            var leaf: [32]u8 = undefined;
            const pack_leaf = try packName(&leaf, index.pack_id, "pack");
            const want: usize = session_pack.record_overhead + entry.compressed_len;
            const buf = try allocator.alloc(u8, want);
            defer allocator.free(buf);
            const got = try self.bytes.readAt(self.bytes.context, pack_leaf, entry.pack_offset, buf);
            if (got != want) return error.TruncatedPack;
            return try self.decode(allocator, buf);
        }
        return null;
    }

    fn decode(self: *PackStore, allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
        _ = self;
        const got = try session_pack.decodeRecordFromSlice(allocator, bytes);
        return got.record.data;
    }

    /// Compacts the sealed packs against `live`: a pack more than 30% dead
    /// has its live objects copied into one new pack, durable and indexed
    /// before the old packs go. Objects waiting to be sealed are untouched.
    pub fn compact(self: *PackStore, live: *const compaction.LiveSet) !Report {
        var plan = try compaction.planCompaction(self.gpa, self.sealed.items, live, self.next_id);
        defer plan.deinit(self.gpa);
        var report: Report = .{};
        for (plan.pack_stats) |s| report.bytes_before += s.total_bytes;
        if (plan.obsolete_packs.len == 0) return report;

        var pack: std.ArrayList(u8) = .empty;
        defer pack.deinit(self.gpa);
        var entries: std.ArrayList(pack_index.Entry) = .empty;
        defer entries.deinit(self.gpa);
        var w: std.Io.Writer.Allocating = .fromArrayList(self.gpa, &pack);
        try session_pack.writeHeader(&w.writer, plan.new_pack_id);
        for (plan.copy_objects) |item| {
            const data = (try self.get(self.gpa, item.object_id)) orelse return error.ObjectMissing;
            defer self.gpa.free(data);
            const offset = w.writer.end;
            const total = try session_pack.encodeRecord(self.gpa, &w.writer, item.object_id, session_pack.flags.page, data);
            try entries.append(self.gpa, .{
                .object_id = item.object_id,
                .xxh3_prefilter = item.object_id.prefilter(),
                .pack_offset = offset,
                .compressed_len = @intCast(total - session_pack.record_overhead),
                .uncompressed_len = item.uncompressed_len,
            });
        }
        pack = w.toArrayList();
        if (entries.items.len > 0) {
            var leaf: [32]u8 = undefined;
            const pack_leaf = try packName(&leaf, plan.new_pack_id, "pack");
            try self.bytes.writeAtomic(self.bytes.context, pack_leaf, pack.items);
            try self.writeIndex(plan.new_pack_id, entries.items);
            const owned = try self.gpa.dupe(pack_index.Entry, entries.items);
            std.mem.sort(pack_index.Entry, owned, {}, pack_index.Entry.order);
            try self.sealed.append(self.gpa, .{ .pack_id = plan.new_pack_id, .entries = owned });
            self.next_id = plan.new_pack_id + 1;
            report.objects_copied = entries.items.len;
            report.bytes_after = pack.items.len;
        }
        for (plan.obsolete_packs) |old| try self.drop(old);
        report.packs_removed = plan.obsolete_packs.len;
        return report;
    }

    fn drop(self: *PackStore, pack_id: u32) !void {
        var leaf: [32]u8 = undefined;
        // The index goes first: a pack without one is rebuilt on open, an
        // index without a pack would name bytes that are gone.
        try self.store.vtable.remove(self.store.context, .objects, try packName(&leaf, pack_id, "idx"));
        try self.store.vtable.remove(self.store.context, .objects, try packName(&leaf, pack_id, "pack"));
        for (self.sealed.items, 0..) |*index, i| {
            if (index.pack_id != pack_id) continue;
            index.deinit(self.gpa);
            _ = self.sealed.orderedRemove(i);
            return;
        }
    }

    fn writeIndex(self: *PackStore, pack_id: u32, entries: []const pack_index.Entry) !void {
        var buf: std.Io.Writer.Allocating = .init(self.gpa);
        defer buf.deinit();
        try pack_index.encode(self.gpa, &buf.writer, pack_id, entries);
        var leaf: [32]u8 = undefined;
        try self.bytes.writeAtomic(self.bytes.context, try packName(&leaf, pack_id, "idx"), buf.written());
    }

    fn load(self: *PackStore, pack_id: u32) !void {
        var leaf: [32]u8 = undefined;
        const idx_leaf = try packName(&leaf, pack_id, "idx");
        const index = self.readIndex(idx_leaf) catch try self.rebuild(pack_id);
        try self.sealed.append(self.gpa, index);
        self.next_id = @max(self.next_id, pack_id + 1);
    }

    fn readIndex(self: *PackStore, leaf: []const u8) !pack_index.Index {
        const len = try self.bytes.length(self.bytes.context, leaf);
        const buf = try self.gpa.alloc(u8, @intCast(len));
        defer self.gpa.free(buf);
        if (try self.bytes.readAt(self.bytes.context, leaf, 0, buf) != buf.len) return error.TruncatedIndex;
        return pack_index.decode(self.gpa, buf);
    }

    fn rebuild(self: *PackStore, pack_id: u32) !pack_index.Index {
        var leaf: [32]u8 = undefined;
        const pack_leaf = try packName(&leaf, pack_id, "pack");
        const len = try self.bytes.length(self.bytes.context, pack_leaf);
        const buf = try self.gpa.alloc(u8, @intCast(len));
        defer self.gpa.free(buf);
        if (try self.bytes.readAt(self.bytes.context, pack_leaf, 0, buf) != buf.len) return error.TruncatedPack;
        const index = try pack_index.rebuildFromPack(self.gpa, buf);
        try self.writeIndex(pack_id, index.entries);
        return index;
    }
};

/// The leaf of pack `id`'s `ext` file (`pack` or `idx`).
pub fn packName(buf: *[32]u8, id: u32, ext: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "pack-{d:0>6}.{s}", .{ id, ext });
}

/// Whether an object-space leaf belongs to the pack store.
pub fn isPackLeaf(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "pack-");
}

const Names = struct {
    gpa: std.mem.Allocator,
    packs: std.ArrayList(u32) = .empty,

    fn deinit(self: *Names) void {
        self.packs.deinit(self.gpa);
    }

    fn visit(context: *anyopaque, name: []const u8, size: u64) anyerror!void {
        _ = size;
        const self: *Names = @ptrCast(@alignCast(context));
        if (!std.mem.startsWith(u8, name, "pack-") or !std.mem.endsWith(u8, name, ".pack")) return;
        const id = std.fmt.parseInt(u32, name[5 .. name.len - 5], 10) catch return;
        try self.packs.append(self.gpa, id);
    }
};
