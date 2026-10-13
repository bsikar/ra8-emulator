//! The owner lease: an exclusive OS lock on `ID.lease` in the history root
//! (flock, or LockFileEx on Windows), held for the life of the process that
//! owns session `ID`. The kernel drops it on any exit, and a stopped
//! process still holds it, so a held lease is the one thing that says a
//! session is live.
//!
//! The lease is made where it stays. It is never renamed and never linked,
//! and it is not inside the directory it guards: some filesystems refuse to
//! move a directory with an open file in it, hide a renamed open file until
//! it is closed, or give a second name of a file a lock of its own.

const std = @import("std");
const name = @import("name.zig");
const metadata = @import("metadata.zig");
const provenance = @import("lease.zig");

pub const State = enum { free, held, missing };

/// Make the lease of a new session `id` in the root `dir` and take it.
/// `PathAlreadyExists` when the name has a lease already.
pub fn create(io: std.Io, dir: std.Io.Dir, id: []const u8) !std.Io.File {
    var buffer: name.Buffer = undefined;
    const file = try dir.createFile(io, try leaf(&buffer, id), .{ .read = true, .exclusive = true });
    errdefer file.close(io);
    try metadata.ordinary(try file.stat(io));
    if (!try file.tryLock(io, .exclusive)) return error.Locked;
    try provenance.write(io, dir, file, id);
    return file;
}

/// Take the lease of session `id` in the root `dir` without waiting. Null
/// when another holder has it; closing the returned file gives it up.
pub fn take(io: std.Io, dir: std.Io.Dir, id: []const u8) !?std.Io.File {
    var buffer: name.Buffer = undefined;
    const entry = try leaf(&buffer, id);
    const file = metadata.open(io, dir, entry, .read_write) catch |err| switch (err) {
        error.FileNotFound, error.OutsideRoot => return error.Unmarked,
        else => return err,
    };
    const got = file.tryLock(io, .exclusive) catch |err| {
        file.close(io);
        return err;
    };
    if (got) {
        provenance.validate(io, dir, file, id) catch {
            file.close(io);
            return error.Unmarked;
        };
        return file;
    }
    file.close(io);
    return null;
}

/// Whether anything holds the lease now. A lease that cannot be read counts
/// as held, so a failure never makes a directory look deletable.
pub fn probe(io: std.Io, dir: std.Io.Dir, id: []const u8) State {
    const file = take(io, dir, id) catch |err| return if (err == error.Unmarked) .missing else .held;
    if (file) |free| {
        free.close(io);
        return .free;
    }
    return .held;
}

/// Give up the held lease of a session whose directory has left the root
/// `dir`, and remove its name. The caller holds the root gate, so nothing
/// takes the free lease in between.
pub fn retire(io: std.Io, dir: std.Io.Dir, id: []const u8, held: std.Io.File) !void {
    var buffer: name.Buffer = undefined;
    const entry = try leaf(&buffer, id);
    var closed = false;
    defer if (!closed) held.close(io);
    try provenance.validate(io, dir, held, id);
    const inode = (try held.stat(io)).inode;
    const current = try metadata.open(io, dir, entry, .read_only);
    defer current.close(io);
    if ((try current.stat(io)).inode != inode) return error.OutsideRoot;
    held.close(io);
    closed = true;
    const after = try dir.statFile(io, entry, .{ .follow_symlinks = false });
    try metadata.ordinary(after);
    if (after.inode != inode) return error.OutsideRoot;
    try dir.deleteFile(io, entry);
}

fn leaf(buffer: *name.Buffer, id: []const u8) ![]const u8 {
    if (!name.isId(id)) return error.BadName;
    return name.lease(buffer, id);
}
