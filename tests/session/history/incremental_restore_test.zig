//! Tests for incremental restore engine: diffing two manifests, copying only
//! differing pages and state blobs, and proving byte-identical equivalence to full restore.
const std = @import("std");
const ra8 = @import("ra8");
const manifest_mod = ra8.session.history_manifest;
const incremental_restore = ra8.session.history_incremental_restore;
const ObjectId = ra8.session.history_object_id.ObjectId;
const scheduler = ra8.chip.core.scheduler;
const memmap = ra8.chip.core.memmap;
const fixture = @import("../board/state_fixture.zig");
const Rig = fixture.Rig;
const populated = fixture.populated;

const at = memmap.sram_base + 0x400;

const MemoryObjectStore = struct {
    map: std.AutoHashMap([16]u8, []const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MemoryObjectStore {
        return .{
            .map = std.AutoHashMap([16]u8, []const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MemoryObjectStore) void {
        var iter = self.map.valueIterator();
        while (iter.next()) |val| {
            self.allocator.free(val.*);
        }
        self.map.deinit();
    }

    pub fn get(context: *anyopaque, id: ObjectId) ?[]const u8 {
        const self: *MemoryObjectStore = @ptrCast(@alignCast(context));
        return self.map.get(id.bytes);
    }

    pub fn put(context: *anyopaque, id: ObjectId, bytes: []const u8) anyerror!void {
        const self: *MemoryObjectStore = @ptrCast(@alignCast(context));
        if (self.map.contains(id.bytes)) return;
        const owned = try self.allocator.dupe(u8, bytes);
        try self.map.put(id.bytes, owned);
    }

    pub fn store(self: *MemoryObjectStore) incremental_restore.ObjectStore {
        return .{
            .context = self,
            .get = &get,
            .put = &put,
        };
    }
};

test "Incremental restore produces byte-identical machine state vs full restore" {
    const allocator = std.testing.allocator;

    var mem_store = MemoryObjectStore.init(allocator);
    defer mem_store.deinit();
    const obj_store = mem_store.store();

    const live = try Rig.create();
    defer live.destroy();
    try populated(live);

    const pos1 = scheduler.Position{ .branch = 1, .r = 10, .phase = .cpu0, .o = 0, .gap = .retired };

    // 1. Capture initial manifest and full snapshot
    var snap1 = try live.save();
    defer snap1.deinit();

    var m1 = try incremental_restore.capture(allocator, &live.files, pos1, 1, null, obj_store);
    defer m1.deinit(allocator);

    // 2. Mutate live machine state across memory and CPU registers
    try live.store.write(.none, at, &.{ 0xaa, 0xbb });
    try live.store.write(.none, at + 0x2000, &.{ 0xcc, 0xdd });
    try live.pair.store.?.write(.none, memmap.mram_base + 0x1000, &.{ 0xee, 0xff });
    live.cpu.slots = 999;
    live.pair.core.cpu.slots = 777;

    const pos2 = scheduler.Position{ .branch = 1, .r = 20, .phase = .cpu0, .o = 5, .gap = .retired };
    var m2 = try incremental_restore.capture(allocator, &live.files, pos2, 2, null, obj_store);
    defer m2.deinit(allocator);

    // 3. Diff m2 (current) vs m1 (target)
    var diff_restore = try manifest_mod.diff(allocator, &m2, &m1);
    defer diff_restore.deinit(allocator);

    // Assert that only the modified pages were scheduled for copying
    try std.testing.expect(diff_restore.pages.len > 0);
    try std.testing.expect(diff_restore.pages.len < m1.pages.len);
    try std.testing.expectEqual(@as(usize, 1), diff_restore.blobs.len);

    // 4. Reference full restore machine
    const ref = try Rig.create();
    defer ref.destroy();
    try populated(ref);
    try ref.store.write(.none, at, &.{ 0xaa, 0xbb });
    try ref.store.write(.none, at + 0x2000, &.{ 0xcc, 0xdd });
    try ref.pair.store.?.write(.none, memmap.mram_base + 0x1000, &.{ 0xee, 0xff });
    ref.cpu.slots = 999;
    ref.pair.core.cpu.slots = 777;

    try ref.files.readFrom(snap1.written());

    // 5. Apply incremental restore to live machine
    try incremental_restore.applyDiff(&live.files, diff_restore, obj_store);

    // 6. Oracle check: full snapshot of live must be 100% byte-identical to ref
    var live_snap = try live.save();
    defer live_snap.deinit();

    var ref_snap = try ref.save();
    defer ref_snap.deinit();

    try std.testing.expectEqualSlices(u8, ref_snap.written(), live_snap.written());
}

test "Incremental restore with identical manifests copies 0 pages" {
    const allocator = std.testing.allocator;

    var mem_store = MemoryObjectStore.init(allocator);
    defer mem_store.deinit();
    const obj_store = mem_store.store();

    const live = try Rig.create();
    defer live.destroy();
    try populated(live);

    const pos = scheduler.Position{ .branch = 1, .r = 15, .phase = .cpu0, .o = 0, .gap = .retired };
    var m = try incremental_restore.capture(allocator, &live.files, pos, 1, null, obj_store);
    defer m.deinit(allocator);

    var empty_diff = try manifest_mod.diff(allocator, &m, &m);
    defer empty_diff.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), empty_diff.pages.len);
    try std.testing.expectEqual(@as(usize, 0), empty_diff.blobs.len);

    // Applying empty diff succeeds without touching state
    try incremental_restore.applyDiff(&live.files, empty_diff, obj_store);
}
