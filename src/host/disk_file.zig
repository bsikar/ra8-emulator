//! A whole disk image read from, or written back over, a host file
//! (RA8EMU-1020). The run works on the copy in memory; only `replace`
//! touches the file, when the application asks it to.
const std = @import("std");

/// The bytes of the file at `path`, at most `max` of them, owned by
/// `allocator`.
pub fn read(allocator: std.mem.Allocator, io: std.Io, path: []const u8, max: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max));
}

/// Write `image` over `path` in `dir`. The bytes go to a sibling temp file,
/// which is fsynced and then renamed over the image, so a write that fails
/// anywhere leaves the old file as it was (RA8EMU-334). The file keeps its
/// permissions. `image` is anything with `writeTo(*std.Io.Writer)`.
pub fn replace(io: std.Io, dir: std.Io.Dir, path: []const u8, image: anytype) !void {
    const kept = if (dir.statFile(io, path, .{})) |stat| stat.permissions else |_| std.Io.File.Permissions.default_file;
    var atomic = try dir.createFileAtomic(io, path, .{ .permissions = kept, .replace = true });
    defer atomic.deinit(io);
    var buffer: [4096]u8 = undefined;
    var out = atomic.file.writer(io, &buffer);
    try image.writeTo(&out.interface);
    try out.interface.flush();
    try atomic.file.sync(io);
    try atomic.replace(io);
}
