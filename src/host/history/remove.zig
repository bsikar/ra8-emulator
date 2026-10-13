//! Deletion policy and the sole recursive delete boundary. Every decision
//! holds the root gate and an OS owner lock, validates markers and host,
//! and resolves the target before rename and before delete.
const std = @import("std");
const layout = @import("layout.zig");
const name = @import("name.zig");
const owner = @import("owner.zig");
const lock = @import("lock.zig");
const machine = @import("machine.zig");
const metadata = @import("metadata.zig");
const provenance = @import("lease.zig");
const rename_file = @import("rename.zig");
const move = @import("move/root.zig");
const Base = @import("base.zig").Base;

pub const Options = struct {
    /// Explicit rm may remove kept sessions, but never a live/foreign one.
    allow_kept: bool = false,
    creating_age_s: i64 = 300,
    now_s: ?i64 = null,
    move_probe: ?move.probe.Probe = null,
};

pub fn discard(root: *const Base, entry: []const u8, id: []const u8) !void {
    const found = name.classify(entry);
    if (!name.isId(id) or !std.mem.eql(u8, found.id, id)) return error.BadName;
    try entryRemove(root, entry, .{});
}

/// No force option. Kept removal requires explicit allow_kept, after the
/// application has obtained its own user confirmation.
pub fn entryRemove(root: *const Base, entry: []const u8, options: Options) !void {
    if (root.role == .runtime) return error.WrongRole;
    const found = name.classify(entry);
    switch (found.kind) {
        .session, .creating, .trash => {},
        else => return error.BadName,
    }
    if (root.role == .kept and !options.allow_kept) return error.Kept;
    var gate = try root.gate(.exclusive);
    defer gate.release();
    try root.owns(entry);
    if (move.intent.pending(root.io, root.dir, found.id)) return error.Moving;
    if (try move.tree.moving(root.io, root.dir, entry)) return error.Moving;
    if (found.kind == .creating) try oldDraft(root, entry, options);
    // The lease is held from here until the directory is gone, and then
    // its name goes too.
    const held = try authorize(root, entry, found.id, options.allow_kept);
    trashed(root, entry, found.kind, found.id, options.move_probe, &.{ gate.file, held }) catch |err| {
        held.close(root.io);
        return err;
    };
    try lock.retire(root.io, root.dir, found.id, held);
}

/// Consume the session's existing lease without unlocking/reacquiring it.
pub fn withHeld(root: *const Base, entry: []const u8, options: Options, held: std.Io.File) !void {
    var held_open = true;
    defer if (held_open) held.close(root.io);
    const found = name.classify(entry);
    if (found.kind != .session) return error.BadName;
    if (root.role == .runtime or (root.role == .kept and !options.allow_kept)) return error.WrongRole;
    var gate = try root.gate(.exclusive);
    defer gate.release();
    try root.owns(entry);
    if (move.intent.pending(root.io, root.dir, found.id)) return error.Moving;
    if (try move.tree.moving(root.io, root.dir, entry)) return error.Moving;
    try provenance.validate(root.io, root.dir, held, found.id);
    var buffer: name.Buffer = undefined;
    const file = try metadata.open(root.io, root.dir, name.lease(&buffer, found.id), .read_only);
    defer file.close(root.io);
    if ((try file.stat(root.io)).inode != (try held.stat(root.io)).inode) return error.OutsideRoot;
    try validateOwner(root, entry, options.allow_kept);
    try trashed(root, entry, found.kind, found.id, options.move_probe, &.{ gate.file, held });
    held_open = false;
    try lock.retire(root.io, root.dir, found.id, held);
}

/// Move `entry` to the trash name of its session and delete it there.
fn trashed(root: *const Base, entry: []const u8, kind: name.Kind, id: []const u8, probe: ?move.probe.Probe, authorities: []const std.Io.File) !void {
    {
        var dir = try root.dir.openDir(root.io, entry, .{ .iterate = true, .follow_symlinks = false });
        defer dir.close(root.io);
        try rename_file.settle(root.io, dir);
    }
    var buffer: name.Buffer = undefined;
    const bin = name.trash(&buffer, id);
    if (kind == .trash) return purgeOwned(root, bin);
    root.dir.access(root.io, bin, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try root.owns(entry);
            try move.dispatch.directory(.{ .source = root, .target = root, .authorities = authorities }, entry, bin, layout.moves.trash, probe);
            return purgeOwned(root, bin);
        },
        else => return err,
    };
    return error.TrashTaken;
}

/// Check the owner record and take the lease, which is handed back held.
fn authorize(root: *const Base, entry: []const u8, id: []const u8, allow_kept: bool) !std.Io.File {
    try validateOwner(root, entry, allow_kept);
    return (try lock.take(root.io, root.dir, id)) orelse return error.Locked;
}

fn validateOwner(root: *const Base, entry: []const u8, allow_kept: bool) !void {
    var dir = try root.dir.openDir(root.io, entry, .{ .follow_symlinks = false });
    defer dir.close(root.io);
    var buffer: [owner.max_bytes]u8 = undefined;
    const record = try owner.read(root.io, dir, &buffer);
    var host: [machine.limits.host]u8 = undefined;
    const local = machine.hostName(&host);
    if (std.mem.eql(u8, local, machine.unknown) or !std.mem.eql(u8, record.host, local)) return error.OtherHost;
    _ = dir.statFile(root.io, layout.files.kept, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (!allow_kept) return error.Kept;
    try metadata.expect(root.io, dir, layout.files.kept, "");
}

fn oldDraft(root: *const Base, entry: []const u8, options: Options) !void {
    if (options.creating_age_s < 0) return error.BadAge;
    const stat = try root.dir.statFile(root.io, entry, .{ .follow_symlinks = false });
    const now = options.now_s orelse std.Io.Timestamp.now(root.io, .real).toSeconds();
    if (@as(i128, now) - stat.mtime.toSeconds() < options.creating_age_s) return error.Young;
}

fn purgeOwned(root: *const Base, bin: []const u8) !void {
    try root.owns(bin);
    try root.dir.deleteTree(root.io, bin);
    root.dir.access(root.io, bin, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return error.DeletePending;
}
