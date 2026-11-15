//! Coalescing directory observation includes direct-child metadata, never link targets.
const std = @import("std");
const entry = @import("entry.zig");
const paths = @import("path.zig");
pub const max_entries = 1024;
pub const Snapshot = struct {
    version: entry.Version = .{},
    children: u64 = 0,
    pub fn same(self: Snapshot, other: Snapshot) bool {
        return std.meta.eql(self, other);
    }
};

pub fn inspect(root: std.Io.Dir, io: std.Io, path: []const u8) !Snapshot {
    const parent = try paths.parent(root, io, path);
    defer parent.close(io);
    const version = try entry.at(parent.dir, io, parent.name);
    if (version.kind != .directory) return .{ .version = version };
    const dir = try parent.dir.openDir(io, parent.name, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);
    if ((try dir.stat(io)).kind != .directory) return error.NotDir;
    var iterator = dir.iterate();
    var count: usize = 0;
    var fingerprint: u64 = 0;
    while (try iterator.next(io)) |item| {
        if (count == max_entries) return error.TooManyEntries;
        const child = try entry.at(dir, io, item.name);
        var hash = std.hash.Wyhash.init(0);
        hash.update(item.name);
        hash.update(std.mem.asBytes(&child.kind));
        hash.update(std.mem.asBytes(&child.size));
        hash.update(std.mem.asBytes(&child.modified_ns));
        hash.update(std.mem.asBytes(&child.identity));
        fingerprint +%= hash.final(); // Independent of directory enumeration order.
        count += 1;
    }
    return .{ .version = version, .children = fingerprint };
}
