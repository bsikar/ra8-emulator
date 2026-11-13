//! Optimistic, staged saves: failed checks never truncate the original file.
const std = @import("std");
const entry = @import("entry.zig");

pub fn save(dir: std.Io.Dir, io: std.Io, name: []const u8, bytes: []const u8, expected: entry.Version) !entry.Version {
    if (!expected.same(try entry.at(dir, io, name))) return error.Conflict;
    if (expected.kind != .file and expected.kind != .missing) return error.NotFile;
    const held = if (expected.kind == .file) try dir.openFile(io, name, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) else null;
    defer if (held) |file| file.close(io);
    const permissions = if (held) |file| blk: {
        const info = try file.stat(io);
        if (!expected.same(try entry.version(info))) return error.Conflict;
        break :blk info.permissions;
    } else std.Io.File.Permissions.default_file;
    var staged = try dir.createFileAtomic(io, name, .{ .replace = expected.kind == .file, .permissions = permissions });
    defer staged.deinit(io);
    try staged.file.writeStreamingAll(io, bytes);
    try staged.file.sync(io);
    if (!expected.same(try entry.at(dir, io, name))) return error.Conflict;
    if (expected.kind == .file) {
        try staged.replace(io);
    } else {
        staged.link(io) catch |err| switch (err) {
            error.PathAlreadyExists => return error.Conflict,
            else => return err,
        };
    }
    return entry.at(dir, io, name);
}
