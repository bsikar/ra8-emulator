//! The image ra8_gui's session starts on (boot.zig): one named on the
//! command line, read before the window opens so a bad path never opens
//! it, or the first one opened in the window.
const std = @import("std");
const shell_open = @import("open.zig");

pub const Image = struct {
    path: []const u8,
    bytes: []const u8,
};

/// Reads `path`, saying why on stderr when it cannot.
pub fn read(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ?Image {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(shell_open.max_image)) catch |err| {
        std.debug.print("cannot read {s}: {s}\n", .{ path, @errorName(err) });
        return null;
    };
    return .{ .path = path, .bytes = bytes };
}

/// As `read`, on a copy of `path`: a window event's path lasts only until
/// the next poll.
pub fn copy(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ?Image {
    const kept = allocator.dupe(u8, path) catch return null;
    return read(allocator, io, kept) orelse {
        allocator.free(kept);
        return null;
    };
}
