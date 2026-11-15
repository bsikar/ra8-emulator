//! Validate source entry kinds, identities, and depth before a directory move.
const h = @import("../root.zig");
const limits = @import("tree.zig").limits;
const std = @import("std");

pub fn preflight(io: std.Io, dir: std.Io.Dir, depth: usize) anyerror!void {
    if (depth >= limits.depth) return error.TooDeep;
    var entries = dir.iterate();
    while (try entries.next(io)) |entry| {
        _ = try h.name.component(entry.name);
        const before = try dir.statFile(io, entry.name, .{ .follow_symlinks = false });
        if (before.kind == .file) {
            if (before.nlink != 1) return error.UnexpectedLinkCount;
        } else if (before.kind == .directory) {
            var child = try dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
            defer child.close(io);
            if ((try child.stat(io)).inode != before.inode) return error.IdentityConflict;
            try preflight(io, child, depth + 1);
        } else return error.UnexpectedKind;
    }
}
