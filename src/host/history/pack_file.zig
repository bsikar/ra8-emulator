//! Format-agnostic byte-moving operations for pack and index files in .objects space.
//!
//! All file operations validate that leaf names are safe single path components
//! inside the session directory's objects area. Atomic file commits write to a
//! temporary file, sync to disk, and atomically rename. Session layer format
//! knowledge is not duplicated here; this file only transfers raw bytes.
const std = @import("std");
const layout = @import("layout.zig");
const paths = @import("paths.zig");
const Session = @import("session.zig").Session;

pub const Storage = struct {
    context: *anyopaque,
    append: *const fn (context: *anyopaque, leaf: []const u8, bytes: []const u8) anyerror!void,
    readAt: *const fn (context: *anyopaque, leaf: []const u8, offset: u64, dest: []u8) anyerror!usize,
    length: *const fn (context: *anyopaque, leaf: []const u8) anyerror!u64,
    sync: *const fn (context: *anyopaque, leaf: []const u8) anyerror!void,
    writeAtomic: *const fn (context: *anyopaque, leaf: []const u8, bytes: []const u8) anyerror!void,
};

fn sessionOf(context: *anyopaque) *Session {
    return @ptrCast(@alignCast(context));
}

/// Appends raw bytes to a file under .objects space, creating it if absent.
pub fn append(session: *const Session, leaf: []const u8, bytes: []const u8) !void {
    _ = try paths.leaf(.objects, leaf);
    const io = session.base.io;
    var dir = try paths.area(session, .objects);
    defer dir.close(io);

    const file = try dir.createFile(io, leaf, .{
        .read = true,
        .truncate = false,
        .resolve_beneath = true,
    });
    defer file.close(io);

    const len = try file.length(io);
    try file.writePositionalAll(io, bytes, len);
}

/// Reads raw bytes at an offset from a file under .objects space.
pub fn readAt(session: *const Session, leaf: []const u8, offset: u64, dest: []u8) !usize {
    _ = try paths.leaf(.objects, leaf);
    const io = session.base.io;
    var dir = try paths.area(session, .objects);
    defer dir.close(io);

    try paths.regular(io, dir, leaf);
    const file = try dir.openFile(io, leaf, .{
        .mode = .read_only,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    defer file.close(io);

    return file.readPositionalAll(io, dest, offset);
}

/// Gets the length of a file under .objects space.
pub fn length(session: *const Session, leaf: []const u8) !u64 {
    _ = try paths.leaf(.objects, leaf);
    const io = session.base.io;
    var dir = try paths.area(session, .objects);
    defer dir.close(io);

    try paths.regular(io, dir, leaf);
    const file = try dir.openFile(io, leaf, .{
        .mode = .read_only,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    defer file.close(io);

    return file.length(io);
}

/// Syncs a file under .objects space.
pub fn sync(session: *const Session, leaf: []const u8) !void {
    _ = try paths.leaf(.objects, leaf);
    const io = session.base.io;
    var dir = try paths.area(session, .objects);
    defer dir.close(io);

    try paths.regular(io, dir, leaf);
    const file = try dir.openFile(io, leaf, .{
        .mode = .read_write,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    defer file.close(io);

    try file.sync(io);
}

/// Atomically replaces a file in .objects space via a temp file write and sync.
pub fn writeAtomic(session: *const Session, leaf: []const u8, bytes: []const u8) !void {
    _ = try paths.leaf(.objects, leaf);
    const io = session.base.io;
    var dir = try paths.area(session, .objects);
    defer dir.close(io);

    var tmp_buf: [128]u8 = undefined;
    const tmp_name = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{leaf});
    _ = try paths.leaf(.objects, tmp_name);

    const tmp_file = try dir.createFile(io, tmp_name, .{
        .read = true,
        .truncate = true,
        .resolve_beneath = true,
    });
    errdefer {
        tmp_file.close(io);
        dir.deleteFile(io, tmp_name) catch {};
    }

    try tmp_file.writeStreamingAll(io, bytes);
    try tmp_file.sync(io);
    tmp_file.close(io);

    try dir.rename(tmp_name, dir, leaf, io);
}

fn vtableAppend(context: *anyopaque, leaf: []const u8, bytes: []const u8) anyerror!void {
    return append(sessionOf(context), leaf, bytes);
}

fn vtableReadAt(context: *anyopaque, leaf: []const u8, offset: u64, dest: []u8) anyerror!usize {
    return readAt(sessionOf(context), leaf, offset, dest);
}

fn vtableLength(context: *anyopaque, leaf: []const u8) anyerror!u64 {
    return length(sessionOf(context), leaf);
}

fn vtableSync(context: *anyopaque, leaf: []const u8) anyerror!void {
    return sync(sessionOf(context), leaf);
}

fn vtableWriteAtomic(context: *anyopaque, leaf: []const u8, bytes: []const u8) anyerror!void {
    return writeAtomic(sessionOf(context), leaf, bytes);
}

/// Returns a Storage vtable bound to the session for injection into session codecs.
pub fn storage(session: *Session) Storage {
    return .{
        .context = session,
        .append = &vtableAppend,
        .readAt = &vtableReadAt,
        .length = &vtableLength,
        .sync = &vtableSync,
        .writeAtomic = &vtableWriteAtomic,
    };
}
