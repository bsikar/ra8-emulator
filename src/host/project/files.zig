//! Rooted project files, read once into the exact bytes later passed to Session.
const std = @import("std");

const entry = @import("../workspace/entry.zig");
const paths = @import("../workspace/path.zig");

pub fn read(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir, name: []const u8, limit: usize) ![]u8 {
    var normalized: [4096]u8 = undefined;
    const parent = try paths.parent(root, io, try paths.normalize(name, &normalized));
    defer parent.close(io);
    const kind = try entry.at(parent.dir, io, parent.name);
    if (kind.kind == .missing) return error.FileNotFound;
    if (kind.kind != .file) return error.NotFile;
    const file = try parent.dir.openFile(io, parent.name, .{ .follow_symlinks = false, .allow_directory = false });
    defer file.close(io);
    const before = try file.stat(io);
    if (before.kind != .file or before.size > limit) return error.ProjectFileLimit;
    const bytes = try allocator.alloc(u8, @intCast(before.size));
    errdefer allocator.free(bytes);
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.ProjectFileChanged;
    const after = try file.stat(io);
    if (before.size != after.size or
        before.mtime.nanoseconds != after.mtime.nanoseconds) return error.ProjectFileChanged;
    return bytes;
}

pub fn directory(io: std.Io, root: std.Io.Dir, name: []const u8) !std.Io.Dir {
    var buffer: [4096]u8 = undefined;
    const normalized = try paths.normalize(name, &buffer);
    if (normalized.len == 0) return root.openDir(io, ".", .{ .iterate = true, .follow_symlinks = false });
    const parent = try paths.parent(root, io, normalized);
    defer parent.close(io);
    return parent.dir.openDir(io, parent.name, .{ .iterate = true, .follow_symlinks = false });
}

pub fn digest(bytes: []const u8) [64]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return std.fmt.bytesToHex(hash, .lower);
}
