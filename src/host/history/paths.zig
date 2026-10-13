//! Resolve a session's immediate directories and files without traversing
//! links. Capabilities do not grant access to lifecycle marker files.
const std = @import("std");
const layout = @import("layout.zig");
const name = @import("name.zig");
const Session = @import("session.zig").Session;

pub fn leaf(space: layout.Space, text: []const u8) ![]const u8 {
    _ = try name.component(text);
    if (@import("move/root.zig").receipt.internal(text)) return error.Reserved;
    if (space == .top and !std.mem.eql(u8, text, layout.files.root) and !std.mem.eql(u8, text, layout.files.branches)) return error.Reserved;
    return text;
}

/// Caller closes the returned handle, including .top's duplicated handle.
pub fn area(session: *const Session, space: layout.Space) !std.Io.Dir {
    try session.base.owns(&session.id);
    const io = session.base.io;
    if (space == .top) return session.dir.openDir(io, ".", .{ .iterate = true, .follow_symlinks = false });
    const text = @tagName(space);
    const stat = try session.dir.statFile(io, text, .{ .follow_symlinks = false });
    if (stat.kind != .directory) return error.OutsideRoot;
    var dir = try session.dir.openDir(io, text, .{ .iterate = true, .follow_symlinks = false });
    errdefer dir.close(io);
    var actual: [std.fs.max_path_bytes]u8 = undefined;
    const len = try dir.realPath(io, &actual);
    const wanted = try std.fmt.allocPrint(session.base.allocator, "{s}{c}{s}{c}{s}", .{ session.base.path, std.fs.path.sep, &session.id, std.fs.path.sep, text });
    defer session.base.allocator.free(wanted);
    if (!std.mem.eql(u8, actual[0..len], wanted)) return error.OutsideRoot;
    return dir;
}

pub fn regular(io: std.Io, dir: std.Io.Dir, text: []const u8) !void {
    const stat = try dir.statFile(io, text, .{ .follow_symlinks = false });
    if (stat.kind != .file) return error.OutsideRoot;
}
