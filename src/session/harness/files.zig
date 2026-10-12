//! The run file behind a served session's snapshot and restore
//! (RA8EMU-768), opened on the serving host. The board encodes and decodes
//! it (src/session/board/state.zig); only this side touches the file
//! (RA8EMU-1020). Paths are confined (RA8EMU-1175): a client names a bare
//! file name, which resolves under `dir` when one is set and in the working
//! directory otherwise, so no listener writes or reads outside that place.
const std = @import("std");
const builtin = @import("builtin");
const session_state = @import("../board/state.zig");

/// The largest file a restore reads.
const max_bytes = 1 << 30;

/// A state path must be a bare file name (RA8EMU-1175): not empty, no
/// separators, not "." or "..", so no absolute or relative path escapes to
/// the serving host's file system.
pub fn bareName(path: []const u8) !void {
    if (path.len == 0) return error.BadStatePath;
    if (std.mem.indexOfAny(u8, path, "/\\") != null) return error.BadStatePath;
    if (std.mem.eql(u8, path, ".") or std.mem.eql(u8, path, "..")) return error.BadStatePath;
}

/// Create `dir_path` and make it owner-only, so other users cannot reach
/// the state files through it (RA8EMU-1175). Skips the mode on Windows.
pub fn harden(io: std.Io, dir_path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, dir_path);
    if (builtin.os.tag != .linux) return;
    // Dir.setPermissions hits a std 0.17 BADF panic on a directory fd, so
    // the mode is set by path.
    const path = std.posix.toPosixPath(dir_path) catch return;
    _ = std.posix.system.fchmodat(std.posix.AT.FDCWD, &path, 0o700, 0);
}

pub const StateFile = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    files: *session_state.Files,
    /// Where snapshots live; null keeps bare names in the working directory.
    dir: ?[]const u8 = null,

    pub fn hook(self: *StateFile) session_state.Hook {
        return .{ .context = self, .saveFn = save, .restoreFn = restore };
    }

    fn resolved(self: *StateFile, path: []const u8) ![]u8 {
        try bareName(path);
        if (self.dir) |dir| return try std.fs.path.join(self.allocator, &.{ dir, path });
        return try self.allocator.dupe(u8, path);
    }

    fn save(context: *anyopaque, path: []const u8) anyerror!void {
        const self: *StateFile = @ptrCast(@alignCast(context));
        try self.files.single();
        const full = try self.resolved(path);
        defer self.allocator.free(full);
        if (self.dir) |dir| try harden(self.io, dir);
        // Written to a sibling temp file and renamed into place once closed,
        // so a half-written snapshot never replaces the one before it
        // (RA8EMU-1175).
        const temp = try std.mem.concat(self.allocator, u8, &.{ full, ".tmp" });
        defer self.allocator.free(temp);
        {
            var out = try std.Io.Dir.cwd().createFile(self.io, temp, .{});
            defer out.close(self.io);
            var buffer: [4096]u8 = undefined;
            var file_writer = out.writer(self.io, &buffer);
            try self.files.writeTo(&file_writer.interface);
            try file_writer.interface.flush();
        }
        try std.Io.Dir.cwd().rename(temp, std.Io.Dir.cwd(), full, self.io);
    }

    fn restore(context: *anyopaque, path: []const u8) anyerror!void {
        const self: *StateFile = @ptrCast(@alignCast(context));
        try self.files.single();
        const full = try self.resolved(path);
        defer self.allocator.free(full);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, full, self.allocator, .limited(max_bytes));
        defer self.allocator.free(bytes);
        try self.files.readFrom(bytes);
    }
};
