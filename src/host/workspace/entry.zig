//! Workspace metadata, independent of wire framing.
const std = @import("std");
pub const Kind = enum(u8) { missing, file, directory, symlink, other };
pub const Version = struct {
    kind: Kind = .missing,
    size: u64 = 0,
    modified_ns: i64 = 0,
    identity: u64 = 0,

    pub fn same(self: Version, other: Version) bool {
        return std.meta.eql(self, other);
    }
};
pub const Entry = struct { name: []const u8, kind: Kind };

pub fn kind(value: std.Io.File.Kind) Kind {
    return switch (value) {
        .file => .file,
        .directory => .directory,
        .sym_link => .symlink,
        else => .other,
    };
}

pub fn version(stat: std.Io.File.Stat) !Version {
    return .{ .kind = kind(stat.kind), .size = stat.size, .modified_ns = std.math.cast(i64, stat.mtime.nanoseconds) orelse return error.InvalidTimestamp, .identity = std.math.cast(u64, stat.inode) orelse return error.InvalidIdentity };
}

pub fn at(dir: std.Io.Dir, io: std.Io, name: []const u8) !Version {
    const stat = dir.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    return version(stat);
}
