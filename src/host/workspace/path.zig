//! Portable workspace-relative paths and no-follow directory traversal.
const std = @import("std");
pub const capacity = 4096;

pub fn normalize(path: []const u8, out: []u8) ![]const u8 {
    if (path.len > capacity) return error.NameTooLong;
    if (path.len != 0 and (path[0] == '/' or path[0] == '\\')) return error.InvalidPath;
    if (std.mem.indexOfAny(u8, path, ":\x00") != null) return error.InvalidPath;
    var parts = std.mem.tokenizeAny(u8, path, "/\\");
    var used: usize = 0;
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) return error.InvalidPath;
        // Windows strips these suffixes; refuse aliases on every platform.
        if (part[part.len - 1] == '.' or part[part.len - 1] == ' ') return error.InvalidPath;
        const needed = part.len + @intFromBool(used != 0);
        if (needed > out.len - used) return error.NameTooLong;
        if (used != 0) {
            out[used] = '/';
            used += 1;
        }
        @memcpy(out[used..][0..part.len], part);
        used += part.len;
    }
    return out[0..used];
}

pub const Parent = struct {
    dir: std.Io.Dir,
    name: []const u8,

    pub fn close(self: Parent, io: std.Io) void {
        self.dir.close(io);
    }
};

/// Every ancestor is opened separately without following a link. `path` is normalized.
pub fn parent(root: std.Io.Dir, io: std.Io, path: []const u8) !Parent {
    var dir = try root.openDir(io, ".", .{ .iterate = true, .follow_symlinks = false });
    errdefer dir.close(io);
    var parts = std.mem.splitScalar(u8, path, '/');
    var name = parts.next().?;
    while (parts.next()) |next| {
        const child = try dir.openDir(io, name, .{ .iterate = true, .follow_symlinks = false });
        const info = child.stat(io) catch |err| {
            child.close(io);
            return err;
        };
        if (info.kind != .directory) {
            child.close(io);
            return error.NotDir;
        }
        dir.close(io);
        dir = child;
        name = next;
    }
    return .{ .dir = dir, .name = if (name.len == 0) "." else name };
}
