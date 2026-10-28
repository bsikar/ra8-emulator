//! Maintenance of a closed disk history: thinning its checkpoints, and
//! re-rooting it at a chosen checkpoint. Both only decide which checkpoints
//! go (the session library's plans); this file carries the decision out by
//! rewriting the log segments without those checkpoints' records and their
//! pictures'. The objects they pinned become orphans for the prune and the
//! pack compaction to reclaim. The segments are rewritten in place, so a
//! session must be closed (the command line holds its lock).
const std = @import("std");
const history = @import("ra8_host").history;
const session = @import("ra8_session");
const record = session.history_record;
const session_log = session.history_log;
const branch_mod = session.history_branch;
const thinning = session.history_thinning;
const reroot_mod = session.history_reroot;
const manifest_mod = session.history_manifest;
const position_mod = session.history_position;
const object_read = @import("object_read.zig");
const segments = @import("history_segments.zig");

pub const Report = struct {
    /// Checkpoints the plan dropped.
    dropped: usize = 0,
    /// Checkpoints left.
    kept: usize = 0,
    /// Branches a re-root left without history (reported, not removed).
    branches_orphaned: usize = 0,
};

/// A checkpoint as the log names it.
const Found = struct { id: u32, position: position_mod.Position, object: [16]u8 };

const Gather = struct {
    allocator: std.mem.Allocator,
    bytes: []const u8,
    list: std.ArrayList(Found) = .empty,
    failed: ?anyerror = null,

    fn see(self: *Gather, boundary: session_log.Boundary) void {
        if (boundary.kind & 0x7FFF != @backingInt(record.Kind.checkpoint)) return;
        const payload = self.bytes[boundary.offset + session.history_format.header_len .. boundary.offset + boundary.consumed];
        const hit = record.decodeCheckpoint(payload) catch return;
        self.list.append(self.allocator, .{ .id = hit.checkpoint.id, .position = hit.header.position, .object = hit.checkpoint.object }) catch |err| {
            self.failed = err;
        };
    }
};

/// Every checkpoint the committed log names, oldest first.
fn checkpoints(allocator: std.mem.Allocator, store: history.storage.Store) ![]Found {
    const bytes = try segments.readAll(allocator, store);
    defer allocator.free(bytes);
    var gather: Gather = .{ .allocator = allocator, .bytes = bytes };
    errdefer gather.list.deinit(allocator);
    _ = try session_log.scan(bytes, &gather, Gather.see);
    if (gather.failed) |err| return err;
    std.mem.sort(Found, gather.list.items, {}, struct {
        fn less(_: void, a: Found, b: Found) bool {
            return a.position.r < b.position.r;
        }
    }.less);
    return gather.list.toOwnedSlice(allocator);
}

/// Thins each line's checkpoints around its newest one: dense behind the
/// cursor, exponentially sparser away, never past `max_replay_gap` rounds
/// between survivors, with fork bases kept.
pub fn thin(allocator: std.mem.Allocator, store: history.storage.Store, graph: *const branch_mod.BranchGraph, max_replay_gap: u64) !Report {
    const all = try checkpoints(allocator, store);
    defer allocator.free(all);
    var dropped: std.ArrayList(u32) = .empty;
    defer dropped.deinit(allocator);
    var line_ids: std.ArrayList(u32) = .empty;
    defer line_ids.deinit(allocator);
    for (all) |c| {
        if (std.mem.indexOfScalar(u32, line_ids.items, c.position.branch) == null) try line_ids.append(allocator, c.position.branch);
    }
    for (line_ids.items) |line| {
        var refs: std.ArrayList(thinning.CheckpointRef) = .empty;
        defer refs.deinit(allocator);
        for (all) |c| if (c.position.branch == line) try refs.append(allocator, .{ .id = c.id, .position = c.position });
        thinning.markForkBases(refs.items, graph);
        const cursor = refs.items[refs.items.len - 1].position;
        var plan = try thinning.planThinning(allocator, refs.items, cursor, .{ .max_replay_gap = max_replay_gap });
        defer plan.deinit(allocator);
        try dropped.appendSlice(allocator, plan.dropped_checkpoints);
    }
    try dropCheckpoints(allocator, store, dropped.items);
    return .{ .dropped = dropped.items.len, .kept = all.len - dropped.items.len };
}

/// Re-roots the history at checkpoint `target`: the history strictly before
/// it on its line is dropped. Refused without `confirm`, and when a pin
/// sits before the new root.
pub fn reroot(allocator: std.mem.Allocator, store: history.storage.Store, graph: *const branch_mod.BranchGraph, target: u32, confirm: bool) !Report {
    const all = try checkpoints(allocator, store);
    defer allocator.free(all);
    var manifests = try allocator.alloc(manifest_mod.Manifest, all.len);
    defer allocator.free(manifests);
    var loaded: usize = 0;
    defer for (manifests[0..loaded]) |*m| m.deinit(allocator);
    var entries = try allocator.alloc(reroot_mod.CheckpointEntry, all.len);
    defer allocator.free(entries);
    for (all, 0..) |c, i| {
        const name = manifest_mod.objectName(c.object);
        const bytes = try object_read.read(store, allocator, &name);
        defer allocator.free(bytes);
        manifests[i] = try manifest_mod.decode(allocator, bytes);
        loaded += 1;
        entries[i] = .{ .id = c.id, .position = c.position, .manifest = &manifests[i] };
    }
    var plan = try reroot_mod.planReroot(allocator, target, confirm, entries, graph, &.{});
    defer plan.deinit(allocator);
    try dropCheckpoints(allocator, store, plan.dropped_checkpoints);
    return .{ .dropped = plan.dropped_checkpoints.len, .kept = all.len - plan.dropped_checkpoints.len, .branches_orphaned = plan.dropped_branches.len };
}

const Cut = struct {
    bytes: []const u8,
    ids: []const u32,
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    failed: ?anyerror = null,

    fn see(self: *Cut, boundary: session_log.Boundary) void {
        const frame = self.bytes[boundary.offset .. boundary.offset + boundary.consumed];
        const kind = boundary.kind & 0x7FFF;
        const shaped = kind == @backingInt(record.Kind.checkpoint) or kind == @backingInt(record.Kind.checkpoint_picture);
        if (shaped) {
            const payload = frame[session.history_format.header_len..];
            if (record.decodeCheckpoint(payload)) |hit| {
                if (std.mem.indexOfScalar(u32, self.ids, hit.checkpoint.id) != null) return;
            } else |_| {}
        }
        self.out.appendSlice(self.allocator, frame) catch |err| {
            self.failed = err;
        };
    }
};

/// Rewrites every log segment without the records of checkpoints `ids`.
fn dropCheckpoints(allocator: std.mem.Allocator, store: history.storage.Store, ids: []const u32) !void {
    if (ids.len == 0) return;
    var names: Names = .{ .allocator = allocator };
    defer names.deinit();
    try store.vtable.list(store.context, .log, .{ .context = &names, .visit = &Names.visit });
    for (names.list.items) |name| try rewrite(allocator, store, name, ids);
}

fn rewrite(allocator: std.mem.Allocator, store: history.storage.Store, name: []const u8, ids: []const u32) !void {
    const file = try store.vtable.open(store.context, .log, name, .update);
    defer file.vtable.close(file.context);
    const length: usize = @intCast(try file.vtable.length(file.context));
    const bytes = try allocator.alloc(u8, length);
    defer allocator.free(bytes);
    var got: usize = 0;
    while (got < length) {
        const n = try file.vtable.read(file.context, got, bytes[got..]);
        if (n == 0) break;
        got += n;
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var cut: Cut = .{ .bytes = bytes[0..got], .ids = ids, .out = &out, .allocator = allocator };
    const walked = try session_log.scan(bytes[0..got], &cut, Cut.see);
    if (cut.failed) |err| return err;
    // A torn tail is not carried over; the log ends at its last whole frame.
    if (out.items.len == walked.complete_end and !walked.torn) return;
    try file.vtable.write(file.context, 0, out.items);
    try file.vtable.truncate(file.context, out.items.len);
    try file.vtable.sync(file.context);
}

const Names = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList([]u8) = .empty,

    fn deinit(self: *Names) void {
        for (self.list.items) |n| self.allocator.free(n);
        self.list.deinit(self.allocator);
    }

    fn visit(context: *anyopaque, name: []const u8, size: u64) anyerror!void {
        _ = size;
        const self: *Names = @ptrCast(@alignCast(context));
        try self.list.append(self.allocator, try self.allocator.dupe(u8, name));
    }
};
