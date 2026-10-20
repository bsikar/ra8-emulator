//! The host's share of the history budget's relief order: the orphans
//! step reclaims the object files no committed record names. The frames
//! step belongs to the ephemeral frame store and the checkpoint-thinning
//! step to the session's checkpoint controller. The prune runs on a root
//! no session holds open, so a staged checkpoint whose object is already
//! on disk is never mistaken for an orphan.

const std = @import("std");
const storage = @import("storage.zig");

/// The bridge that names the referenced objects. The session library
/// walks the committed frames; the applications wire it here, the same
/// callback shape the recorder's bind uses.
pub const Referrer = struct {
    /// Adds every object name the store's committed log names into
    /// `names`. The names' keys are allocated with `allocator`; the
    /// prune frees them.
    collect: *const fn (store: storage.Store, allocator: std.mem.Allocator, names: *std.StringHashMap(void)) anyerror!void,
};

pub const Report = struct {
    /// Object files the objects space dropped.
    orphans: usize = 0,
    /// Bytes the orphan files held.
    orphan_bytes: u64 = 0,
};

/// Reclaims the object files the committed log does not name. A log the
/// referrer cannot fully read is a hard error, so the sweep never
/// deletes past an unreadable segment.
pub fn orphans(store: storage.Store, allocator: std.mem.Allocator, referrer: Referrer) !Report {
    var names = std.StringHashMap(void).init(allocator);
    defer {
        var it = names.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        names.deinit();
    }
    try referrer.collect(store, allocator, &names);

    var sweep = Sweep{ .store = store, .names = &names };
    try store.vtable.list(store.context, .objects, .{ .context = &sweep, .visit = &Sweep.visit });
    return .{ .orphans = sweep.count, .orphan_bytes = sweep.bytes };
}

const Sweep = struct {
    store: storage.Store,
    names: *const std.StringHashMap(void),
    count: usize = 0,
    bytes: u64 = 0,

    fn visit(context: *anyopaque, name: []const u8, size: u64) anyerror!void {
        const self: *Sweep = @ptrCast(@alignCast(context));
        if (self.names.contains(name)) return;
        try self.store.vtable.remove(self.store.context, .objects, name);
        self.count += 1;
        self.bytes += size;
    }
};

/// The frames step of the relief order. The frames space holds only the
/// frame cache: its files are delete-on-close (the open path unlinks the
/// name on POSIX and opens delete-on-close on Windows), so no record the
/// committed log carries names one, and a file still listed there is a
/// cache entry no handle holds or a leftover the close path never got to
/// remove. The sweep drops every file it lists and reports what it
/// reclaimed; a removal that fails is a hard error, so relief never
/// claims bytes it did not get back.
pub const FrameReport = struct {
    /// Frame-cache files the frames space dropped.
    frames: usize = 0,
    /// Bytes the dropped files held.
    frame_bytes: u64 = 0,
};

pub fn frames(store: storage.Store) !FrameReport {
    var sweep = FrameSweep{ .store = store };
    try store.vtable.list(store.context, .frames, .{ .context = &sweep, .visit = &FrameSweep.visit });
    return .{ .frames = sweep.count, .frame_bytes = sweep.bytes };
}

const FrameSweep = struct {
    store: storage.Store,
    count: usize = 0,
    bytes: u64 = 0,

    fn visit(context: *anyopaque, name: []const u8, size: u64) anyerror!void {
        const self: *FrameSweep = @ptrCast(@alignCast(context));
        try self.store.vtable.remove(self.store.context, .frames, name);
        self.count += 1;
        self.bytes += size;
    }
};
