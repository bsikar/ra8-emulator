//! Object references protected by committed logs and checkpoint pictures.
const history = @import("ra8_host").history;
const history_live = @import("history_live.zig");
const session_refs = @import("ra8_session").history_refs;
const std = @import("std");

/// The host prune's referrer: names every object the committed log
/// names. Reads the store's log segments and walks each one's committed
/// frames through the session library's scan; a segment the walk cannot
/// finish is a hard error, so the sweep never deletes past it.
pub const prune_referrer: history.prune.Referrer = .{ .collect = &collectReferenced, .pictures = &collectPictures };

const PruneGather = struct {
    allocator: std.mem.Allocator,
    names: *std.StringHashMap(void),
    failed: ?anyerror = null,

    fn add(self: *PruneGather, name: session_refs.Name) void {
        if (self.failed != null) return;
        const key = self.allocator.dupe(u8, &name) catch {
            self.failed = error.OutOfMemory;
            return;
        };
        const hit = self.names.getOrPut(key) catch {
            self.allocator.free(key);
            self.failed = error.OutOfMemory;
            return;
        };
        if (hit.found_existing) self.allocator.free(key);
    }
};

const PruneSegments = struct {
    store: history.storage.Store,
    gather: *PruneGather,
    /// Name only the checkpoint pictures, not every committed object.
    pictures_only: bool = false,

    fn visit(context: *anyopaque, name: []const u8, size: u64) anyerror!void {
        _ = size;
        const self: *PruneSegments = @ptrCast(@alignCast(context));
        const file = try self.store.vtable.open(self.store.context, .log, name, .read);
        defer file.vtable.close(file.context);
        const length: usize = @intCast(try file.vtable.length(file.context));
        const bytes = try self.gather.allocator.alloc(u8, length);
        defer self.gather.allocator.free(bytes);
        var got: usize = 0;
        while (got < bytes.len) {
            const read = try file.vtable.read(file.context, got, bytes[got..]);
            if (read == 0) break;
            got += read;
        }
        const walked = if (self.pictures_only)
            session_refs.scanPictureObjects(bytes[0..got], self.gather, PruneGather.add)
        else
            session_refs.scanCheckpointObjects(bytes[0..got], self.gather, PruneGather.add);
        walked catch |err| {
            self.gather.failed = err;
        };
    }
};

fn collectReferenced(
    store: history.storage.Store,
    allocator: std.mem.Allocator,
    names: *std.StringHashMap(void),
) anyerror!void {
    return collect(store, allocator, names, false);
}

/// The checkpoint pictures' object names alone, which relief protects
/// by name and counts.
fn collectPictures(
    store: history.storage.Store,
    allocator: std.mem.Allocator,
    names: *std.StringHashMap(void),
) anyerror!void {
    return collect(store, allocator, names, true);
}

fn collect(
    store: history.storage.Store,
    allocator: std.mem.Allocator,
    names: *std.StringHashMap(void),
    pictures_only: bool,
) anyerror!void {
    var gather = PruneGather{ .allocator = allocator, .names = names };
    var segments = PruneSegments{ .store = store, .gather = &gather, .pictures_only = pictures_only };
    try store.vtable.list(store.context, .log, .{ .context = &segments, .visit = &PruneSegments.visit });
    if (gather.failed) |err| return err;
    if (!pictures_only) try history_live.addManifestObjects(store, allocator, names);
}
