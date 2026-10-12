//! Normalize Unix socket names before std.Io.net opens native Windows AFD.
const std = @import("std");
const builtin = @import("builtin");

/// Resolve the existing parent, leaving the not-yet-created socket alone.
/// POSIX retains its relative and abstract address semantics.
pub fn unix(io: std.Io, name: []const u8, buffer: []u8) ![]const u8 {
    if (builtin.os.tag != .windows or (name.len != 0 and name[0] == 0)) return name;
    const parent = std.fs.path.dirname(name) orelse ".";
    var canonical: [std.fs.max_path_bytes]u8 = undefined;
    const len = try std.Io.Dir.cwd().realPathFile(io, parent, &canonical);
    return std.fmt.bufPrint(buffer, "{s}\\{s}", .{ canonical[0..len], std.fs.path.basename(name) });
}
