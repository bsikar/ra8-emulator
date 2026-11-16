//! Portable archive names and no-follow cache directory traversal.
const builtin = @import("builtin");
const ownership = @import("ownership.zig");
const std = @import("std");

pub const private: std.Io.File.Permissions = if (builtin.os.tag == .windows)
    .default_dir
else
    .fromMode(0o700);

pub fn name(text: []const u8) ![]const u8 {
    if (text.len == 0 or text.len > 4096 or text[0] == '/') return error.UnsafeArchivePath;
    const clean = std.mem.trimEnd(u8, text, "/");
    var parts = std.mem.splitScalar(u8, clean, '/');
    while (parts.next()) |part| {
        try component(part);
    }
    return clean;
}

fn component(part: []const u8) !void {
    if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.UnsafeArchivePath;
    if (part[part.len - 1] == '.' or part[part.len - 1] == ' ') return error.UnsafeArchivePath;
    for (part) |byte| {
        if (byte < 32 or byte >= 127 or std.mem.indexOfScalar(u8, "\\:<>\"|?*", byte) != null) {
            return error.UnsafeArchivePath;
        }
    }
    const stem = part[0 .. std.mem.indexOfScalar(u8, part, '.') orelse part.len];
    for ([_][]const u8{
        "con",  "prn",  "aux",  "nul",  "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9",
        "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9",
    }) |reserved| {
        if (std.ascii.eqlIgnoreCase(stem, reserved)) return error.UnsafeArchivePath;
    }
}

pub fn regular(io: std.Io, dir: std.Io.Dir, path: []const u8) !std.Io.File {
    const info = try dir.statFile(io, path, .{ .follow_symlinks = false });
    if (info.kind != .file or info.nlink != 1) return error.UnsafeCacheEntry;
    const file = try dir.openFile(io, path, .{ .follow_symlinks = false, .resolve_beneath = true });
    errdefer file.close(io);
    const opened = try file.stat(io);
    if (opened.inode != info.inode or opened.kind != .file or opened.nlink != 1) return error.UnsafeCacheEntry;
    try ownership.file(io, file);
    return file;
}

/// Every component is opened separately; a link/reparse point is never followed.
pub fn descend(io: std.Io, root: std.Io.Dir, path: []const u8, create: bool) !std.Io.Dir {
    return walk(io, root, path, create, true);
}

pub fn enter(io: std.Io, dir: std.Io.Dir, part: []const u8, create: bool) !std.Io.Dir {
    try component(part);
    try ownership.directory(io, dir);
    return openChild(io, dir, part, create, true);
}

fn walk(io: std.Io, root: std.Io.Dir, path: []const u8, create: bool, protected: bool) !std.Io.Dir {
    var dir = try root.openDir(io, ".", .{ .iterate = true, .follow_symlinks = false });
    errdefer dir.close(io);
    var parts = std.mem.tokenizeAny(u8, path, "/\\");
    while (parts.next()) |part| {
        try component(part);
        if (protected) {
            try ownership.directory(io, dir);
        } else {
            try ownership.ancestor(io, dir);
        }
        const child = try openChild(io, dir, part, create, protected);
        dir.close(io);
        dir = child;
    }
    return dir;
}

fn createChild(io: std.Io, dir: std.Io.Dir, part: []const u8, create: bool) !bool {
    if (!create) return false;
    dir.createDir(io, part, private) catch |err| switch (err) {
        error.PathAlreadyExists => return false,
        else => return err,
    };
    return true;
}

fn openChild(io: std.Io, dir: std.Io.Dir, part: []const u8, create: bool, protected: bool) !std.Io.Dir {
    const created = try createChild(io, dir, part, create);
    const child = try dir.openDir(io, part, .{ .iterate = true, .follow_symlinks = false });
    errdefer child.close(io);
    if ((try child.stat(io)).kind != .directory) return error.UnsafeCacheEntry;
    if (created) try ownership.makePrivate(io, child);
    if (protected) try ownership.directory(io, child);
    return child;
}

pub fn cache(io: std.Io, absolute: []const u8, create: bool) !std.Io.Dir {
    if (!std.fs.path.isAbsolute(absolute)) return error.InvalidToolPath;
    const disk = if (builtin.os.tag == .windows) std.fs.path.diskDesignatorWindows(absolute) else "/";
    if (builtin.os.tag == .windows and (disk.len != 2 or disk[1] != ':')) return error.LocalCacheRequired;
    var buffer: [4]u8 = undefined;
    const volume = if (builtin.os.tag == .windows)
        try std.fmt.bufPrint(&buffer, "{s}\\", .{disk})
    else
        disk;
    var root = try std.Io.Dir.openDirAbsolute(io, volume, .{ .iterate = true, .follow_symlinks = false });
    defer root.close(io);
    const dir = try walk(io, root, absolute[disk.len..], create, false);
    errdefer dir.close(io);
    try ownership.directory(io, dir);
    return dir;
}
