//! Offline command line branch operations for persistent histories (Slice 20.4).
const std = @import("std");
const ra8_host = @import("ra8_host");
const history = ra8_host.history;
const branches_file = history.branches_file;
const ra8_session = @import("ra8_session");
const lifecycle = ra8_session.history_lifecycle;
const branches_recover = ra8_session.history_branches_recover;
const codec = ra8_session.history_branches_codec;

fn printBranchItems(out: *std.Io.Writer, items: []const lifecycle.BranchInfo) !void {
    for (items) |it| {
        try out.print("branch {d}: parent {d}, fork {d}, end {d}, children {d} ({s})", .{
            it.id,
            it.parent,
            it.fork_at.r,
            it.recorded_end.r,
            it.child_count,
            @tagName(it.reason),
        });
        if (it.is_live) try out.writeAll(", live");
        if (it.is_kept) try out.writeAll(", kept");
        if (it.is_pinned) try out.writeAll(", pinned");
        try out.writeAll("\n");
    }
}

fn listOneSession(allocator: std.mem.Allocator, base: *const history.base.Base, name: []const u8, out: *std.Io.Writer) !void {
    var dir = try base.dir.openDir(base.io, name, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(base.io);

    var candidates = try branches_file.readCandidates(base.io, dir, allocator);
    defer candidates.deinit(allocator);

    var rec = try branches_recover.recover(allocator, candidates.current, candidates.temp, null);
    defer rec.graph.deinit();

    const items = try lifecycle.list(allocator, &rec.graph, 0);
    defer allocator.free(items);

    try printBranchItems(out, items);
}

pub fn listBranches(allocator: std.mem.Allocator, base: *const history.base.Base, session_name: ?[]const u8, out: *std.Io.Writer) !u8 {
    if (session_name) |name| {
        try listOneSession(allocator, base, name, out);
        return 0;
    }

    var entries = try history.catalog.Iterator.init(base);
    while (try entries.next()) |entry| {
        if (entry.kind != .session) continue;
        try out.print("session {s}:\n", .{entry.name});
        listOneSession(allocator, base, entry.name, out) catch |err| {
            try out.print("  error: {s}\n", .{@errorName(err)});
        };
    }
    return 0;
}

pub fn removeBranch(
    allocator: std.mem.Allocator,
    base: *const history.base.Base,
    session_name: []const u8,
    branch_id: u32,
    confirm: bool,
    out: *std.Io.Writer,
) !u8 {
    if (!confirm) return error.ConfirmRequired;

    var dir = try base.dir.openDir(base.io, session_name, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(base.io);

    var id: history.name.Id = undefined;
    @memcpy(&id, history.name.classify(session_name).id);
    const held = (try history.lock.take(base.io, base.dir, &id)) orelse return error.SessionLocked;
    defer held.close(base.io);

    try history.rename.settle(base.io, dir);

    var candidates = try branches_file.readCandidates(base.io, dir, allocator);
    defer candidates.deinit(allocator);

    var rec = try branches_recover.recover(allocator, candidates.current, candidates.temp, null);
    defer rec.graph.deinit();

    // A branches.bin that is there but decodes to nothing is not an empty
    // history: writing the base-only graph back would drop every branch
    // while reporting a removal, so the removal refuses and the file stays.
    if (rec.action == .use_base and (candidates.current != null or candidates.temp != null))
        return error.BranchesUnreadable;
    switch (rec.action) {
        .use_temp => try branches_file.settle(base.io, dir),
        .use_current, .use_base => branches_file.cleanupTemp(base.io, dir),
    }

    const plan = try lifecycle.removeBranchPure(&rec.graph, null, branch_id, confirm);
    const encoded = try codec.encodeAlloc(&rec.graph, allocator);
    defer allocator.free(encoded);

    try branches_file.writeAtomic(base.io, dir, encoded);
    try out.print("removed branch {d} ({s})\n", .{ branch_id, @tagName(plan.kind) });
    return 0;
}
