//! Format-agnostic crash-safe host-side file operations for branches.bin metadata.
//!
//! Commits write to a temporary file, flush/sync to disk, and atomically
//! replace branches.bin. Reads candidate raw bytes for branches.bin and any
//! leftover temporary file so session-layer recovery can decide which to adopt.
const std = @import("std");
const layout = @import("layout.zig");
const name = @import("name.zig");

pub const file_name = layout.files.branches;
pub const temp_name = layout.files.branches ++ ".tmp";

pub const max_file_size: usize = 16 * 1024 * 1024;

/// Raw byte buffers for the current file and any leftover temporary file.
pub const Candidates = struct {
    current: ?[]u8 = null,
    temp: ?[]u8 = null,

    /// Releases any allocated byte buffers.
    pub fn deinit(self: *Candidates, allocator: std.mem.Allocator) void {
        if (self.current) |c| allocator.free(c);
        if (self.temp) |t| allocator.free(t);
        self.* = .{};
    }
};

/// Atomically writes bytes to branches.bin by writing to a temporary file,
/// syncing it to disk, and performing an atomic rename.
pub fn writeAtomic(io: std.Io, dir: std.Io.Dir, bytes: []const u8) !void {
    _ = try name.component(temp_name);
    _ = try name.component(file_name);

    const temp_file = try dir.createFile(io, temp_name, .{
        .read = true,
        .truncate = true,
        .resolve_beneath = true,
    });
    errdefer {
        temp_file.close(io);
        dir.deleteFile(io, temp_name) catch {};
    }

    try temp_file.writeStreamingAll(io, bytes);
    try temp_file.sync(io);
    temp_file.close(io);

    try dir.rename(temp_name, dir, file_name, io);
    // Note: std.Io does not expose a directory sync method on std.Io.Dir
    // in Zig 0.17; directory metadata persistency on POSIX relies on filesystem
    // journaling or direct os fsync where accessible.
}

/// Reads the entire contents of a leaf file if present, returning null if not found.
pub fn readAlloc(
    io: std.Io,
    dir: std.Io.Dir,
    leaf: []const u8,
    allocator: std.mem.Allocator,
) !?[]u8 {
    _ = try name.component(leaf);
    const file = dir.openFile(io, leaf, .{
        .mode = .read_only,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.size > max_file_size) return error.FileTooBig;
    const buf = try allocator.alloc(u8, @intCast(stat.size));
    errdefer allocator.free(buf);

    var done: usize = 0;
    while (done < buf.len) {
        const read_count = try file.readPositionalAll(io, buf[done..], done);
        if (read_count == 0) return error.ShortRead;
        done += read_count;
    }
    return buf;
}

/// Reads raw candidate byte buffers for both current branches.bin and leftover temp file.
pub fn readCandidates(
    io: std.Io,
    dir: std.Io.Dir,
    allocator: std.mem.Allocator,
) !Candidates {
    var candidates = Candidates{};
    errdefer candidates.deinit(allocator);

    candidates.current = try readAlloc(io, dir, file_name, allocator);
    candidates.temp = try readAlloc(io, dir, temp_name, allocator);
    return candidates;
}

/// Settles a valid temporary file into branches.bin via atomic rename.
pub fn settle(io: std.Io, dir: std.Io.Dir) !void {
    _ = try name.component(temp_name);
    _ = try name.component(file_name);
    try dir.rename(temp_name, dir, file_name, io);
}

/// Deletes any leftover temporary file.
pub fn cleanupTemp(io: std.Io, dir: std.Io.Dir) void {
    dir.deleteFile(io, temp_name) catch {};
}
