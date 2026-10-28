//! Offline maintenance of a closed persistent history: `thin` and `reroot`
//! rewrite a session's log without the checkpoints their plans drop, and
//! both finish with the orphan sweep and the pack compaction that give the
//! dropped checkpoints' bytes back. The session's lock is held throughout,
//! so a live session is never touched.
const std = @import("std");
const history = @import("ra8_host").history;
const rpc = @import("ra8_rpc");
const session_lib = @import("ra8_session");
const branches_file = history.branches_file;
const branches_recover = session_lib.history_branches_recover;

/// A session opened for maintenance: its lock held, renames settled, and
/// the store the recorder itself uses.
pub const Open = struct {
    dir: std.Io.Dir,
    held: std.Io.File,
    session: history.session.Session,
    base: *const history.base.Base,

    pub fn open(base: *const history.base.Base, name: []const u8, kept: bool) !Open {
        var dir = try base.dir.openDir(base.io, name, .{ .iterate = true, .follow_symlinks = false });
        errdefer dir.close(base.io);
        var id: history.name.Id = undefined;
        @memcpy(&id, history.name.classify(name).id);
        const held = (try history.lock.take(base.io, base.dir, &id)) orelse return error.SessionLocked;
        errdefer held.close(base.io);
        try history.rename.settle(base.io, dir);
        return .{ .dir = dir, .held = held, .session = .{ .base = base, .id = id, .dir = dir, .lock = held, .kept = kept }, .base = base };
    }

    pub fn close(self: *Open) void {
        self.held.close(self.base.io);
        self.dir.close(self.base.io);
    }

    pub fn store(self: *Open) history.storage.Store {
        return history.storage.Store.from(&self.session);
    }
};

/// The orphan sweep and the pack compaction, the two steps that reclaim
/// what dropped checkpoints held.
pub fn reclaim(allocator: std.mem.Allocator, opened: *Open, out: *std.Io.Writer) !void {
    const store = opened.store();
    const swept = try history.prune.relief(store, allocator, rpc.history_bind.prune_referrer);
    const packs = try rpc.pack_store.PackStore.open(allocator, &opened.session);
    defer packs.close();
    const compacted = try rpc.history_live.compactPacks(store, allocator, packs, rpc.history_bind.prune_referrer.collect);
    try out.print("reclaimed {d} orphan objects ({d} bytes), {d} packs compacted ({d} -> {d} bytes)\n", .{ swept.orphans, swept.orphan_bytes, compacted.packs_removed, compacted.bytes_before, compacted.bytes_after });
}

fn graphOf(allocator: std.mem.Allocator, opened: *Open) !session_lib.history_branch.BranchGraph {
    var candidates = try branches_file.readCandidates(opened.base.io, opened.dir, allocator);
    defer candidates.deinit(allocator);
    const rec = try branches_recover.recover(allocator, candidates.current, candidates.temp, null);
    return rec.graph;
}

/// Thins session `name`'s checkpoints so no two survivors are more than
/// `gap` rounds apart.
pub fn thin(allocator: std.mem.Allocator, base: *const history.base.Base, name: []const u8, kept: bool, gap: u64, out: *std.Io.Writer) !u8 {
    var opened = try Open.open(base, name, kept);
    defer opened.close();
    var graph = try graphOf(allocator, &opened);
    defer graph.deinit();
    const report = try rpc.history_maint.thin(allocator, opened.store(), &graph, gap);
    try out.print("{s}: thinned, {d} checkpoints dropped, {d} kept\n", .{ name, report.dropped, report.kept });
    try reclaim(allocator, &opened, out);
    return 0;
}

/// Re-roots session `name` at checkpoint `target`; `confirm` must be set.
pub fn reroot(allocator: std.mem.Allocator, base: *const history.base.Base, name: []const u8, kept: bool, target: u32, confirm: bool, out: *std.Io.Writer) !u8 {
    var opened = try Open.open(base, name, kept);
    defer opened.close();
    var graph = try graphOf(allocator, &opened);
    defer graph.deinit();
    const report = try rpc.history_maint.reroot(allocator, opened.store(), &graph, target, confirm);
    try out.print("{s}: re-rooted at checkpoint {d}, {d} checkpoints dropped, {d} kept, {d} branches left without history\n", .{ name, target, report.dropped, report.kept, report.branches_orphaned });
    try reclaim(allocator, &opened, out);
    return 0;
}
