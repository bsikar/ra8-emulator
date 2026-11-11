//! The run file behind a served session's snapshot and restore
//! (RA8EMU-768, ADR 0004 D20). `src/session/board/state.zig` encodes and
//! decodes the snapshot; host storage goes through an injected
//! `file_ops.StateStore`. Paths are confined (RA8EMU-1175): only bare file
//! names pass validation before any storage hook runs.
const std = @import("std");
const file_ops = @import("../file_ops.zig");
const session_state = @import("../board/state.zig");

/// The largest file a restore reads.
pub const max_bytes = 1 << 30;

/// A state path must be a bare file name (RA8EMU-1175): not empty, no `/` or
/// `\`, no drive colon `:`, no NUL byte, and not `.` or `..`, so no absolute
/// or relative path escapes to the serving host's file system.
pub fn bareName(path: []const u8) !void {
    if (path.len == 0) return error.BadStatePath;
    if (std.mem.indexOfAny(u8, path, "/\\:\x00") != null) return error.BadStatePath;
    if (std.mem.eql(u8, path, ".") or std.mem.eql(u8, path, "..")) return error.BadStatePath;
}

pub const StateFile = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    files: *session_state.Files,
    /// Where snapshots live; null keeps bare names in the store's base directory.
    dir: ?[]const u8 = null,
    /// Host-provided state persistence (ADR 0004 D20); null refuses file access.
    store: ?file_ops.StateStore = null,

    pub fn hook(self: *StateFile) session_state.Hook {
        return .{ .context = self, .saveFn = save, .restoreFn = restore };
    }

    fn writeSnapshot(context: *anyopaque, writer: *std.Io.Writer) anyerror!void {
        const files: *session_state.Files = @ptrCast(@alignCast(context));
        try files.writeTo(writer);
    }

    fn save(context: *anyopaque, path: []const u8) anyerror!void {
        const self: *StateFile = @ptrCast(@alignCast(context));
        try bareName(path);
        try self.files.single();
        const store = self.store orelse return error.NoStateFiles;
        try store.save(self.io, self.dir, path, self.files, writeSnapshot);
    }

    fn restore(context: *anyopaque, path: []const u8) anyerror!void {
        const self: *StateFile = @ptrCast(@alignCast(context));
        try bareName(path);
        try self.files.single();
        const store = self.store orelse return error.NoStateFiles;
        const bytes = try store.restore(self.io, self.allocator, self.dir, path, max_bytes);
        defer self.allocator.free(bytes);
        try self.files.readFrom(bytes);
    }
};
