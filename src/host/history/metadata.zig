//! Immutable metadata. Existing paths are never truncated or followed.
//! A handle and its directory entry must describe one ordinary file with
//! one link before it can authorize a root, owner, lock or kept marker.
const std = @import("std");
const name = @import("name.zig");

pub fn open(io: std.Io, dir: std.Io.Dir, leaf: []const u8, mode: std.Io.Dir.OpenFileOptions.Mode) !std.Io.File {
    _ = try name.component(leaf);
    const before = try dir.statFile(io, leaf, .{ .follow_symlinks = false });
    try ordinary(before);
    const file = try dir.openFile(io, leaf, .{ .mode = mode, .follow_symlinks = false, .resolve_beneath = true });
    errdefer file.close(io);
    const actual = try file.stat(io);
    try ordinary(actual);
    const after = try dir.statFile(io, leaf, .{ .follow_symlinks = false });
    try ordinary(after);
    if (before.inode != actual.inode or after.inode != actual.inode) return error.OutsideRoot;
    return file;
}

/// Exclusively create new metadata. Preserve existing exact bytes, or
/// refuse. In particular no open of an existing name ever requests writes.
pub fn ensure(io: std.Io, dir: std.Io.Dir, leaf: []const u8, text: []const u8) !void {
    _ = try name.component(leaf);
    if (dir.statFile(io, leaf, .{ .follow_symlinks = false })) |_| {
        return expect(io, dir, leaf, text);
    } else |err| if (err != error.FileNotFound) return err;
    const file = dir.createFile(io, leaf, .{ .read = true, .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return expect(io, dir, leaf, text),
        else => return err,
    };
    defer file.close(io);
    try ordinary(try file.stat(io));
    try file.writeStreamingAll(io, text);
    try file.sync(io);
}

pub fn expect(io: std.Io, dir: std.Io.Dir, leaf: []const u8, text: []const u8) !void {
    const file = try open(io, dir, leaf, .read_only);
    defer file.close(io);
    if ((try file.stat(io)).size != text.len) return error.BadMetadata;
    var buffer: [256]u8 = undefined;
    var offset: usize = 0;
    while (offset < text.len) {
        const part = buffer[0..@min(buffer.len, text.len - offset)];
        if (try file.readPositionalAll(io, part, offset) != part.len) return error.BadMetadata;
        if (!std.mem.eql(u8, part, text[offset..][0..part.len])) return error.BadMetadata;
        offset += part.len;
    }
}

/// Read through the checked handle, never by reopening the path.
pub fn read(io: std.Io, dir: std.Io.Dir, leaf: []const u8, buffer: []u8) ![]const u8 {
    const file = try open(io, dir, leaf, .read_only);
    defer file.close(io);
    const size = (try file.stat(io)).size;
    if (size > buffer.len) return error.BadMetadata;
    const text = buffer[0..@intCast(size)];
    if (try file.readPositionalAll(io, text, 0) != text.len) return error.BadMetadata;
    return text;
}

pub fn ordinary(stat: std.Io.File.Stat) error{OutsideRoot}!void {
    if (stat.kind != .file or stat.nlink != 1) return error.OutsideRoot;
}

pub fn empty(io: std.Io, dir: std.Io.Dir, leaf: []const u8, mode: std.Io.Dir.OpenFileOptions.Mode) !std.Io.File {
    const file = try open(io, dir, leaf, mode);
    errdefer file.close(io);
    if ((try file.stat(io)).size != 0) return error.BadMetadata;
    return file;
}

/// CACHEDIR.TAG permits extra comments after its standard signature. Keep
/// any such existing valid tag byte for byte instead of replacing it.
pub fn ensureTag(io: std.Io, dir: std.Io.Dir, leaf: []const u8, text: []const u8) !void {
    ensure(io, dir, leaf, text) catch |err| {
        if (err != error.BadMetadata) return err;
        const file = try open(io, dir, leaf, .read_only);
        defer file.close(io);
        const prefix = text[0 .. (std.mem.indexOfScalar(u8, text, '\n') orelse return error.BadMetadata) + 1];
        var buffer: [128]u8 = undefined;
        if (prefix.len > buffer.len) return error.BadMetadata;
        const actual = buffer[0..prefix.len];
        if (try file.readPositionalAll(io, actual, 0) != actual.len) return error.BadMetadata;
        if (!std.mem.eql(u8, prefix, actual)) return error.BadMetadata;
    };
}
