//! A whole disk image read from a host file (RA8EMU-1020). The run works on
//! the copy in memory and never writes back to the file.
const std = @import("std");

/// The bytes of the file at `path`, at most `max` of them, owned by
/// `allocator`.
pub fn read(allocator: std.mem.Allocator, io: std.Io, path: []const u8, max: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max));
}
