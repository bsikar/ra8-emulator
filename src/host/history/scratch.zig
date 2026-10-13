//! Frame-cache and scratch files: files in a session's `frames/` and
//! `scratch/` that the host removes by itself when they are closed, or when
//! the process dies holding them. POSIX unlinks the name right after the
//! open; Windows opens with FILE_FLAG_DELETE_ON_CLOSE.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../win32.zig");
const name = @import("name.zig");
const Session = @import("session.zig").Session;
const paths = @import("paths.zig");

pub const Area = enum { frames, scratch };

const access = struct {
    pub const generic_read_write: win32.DWORD = 0xC000_0000;
    pub const share_all: win32.DWORD = 0x7;
    pub const create_new: win32.DWORD = 1;
    pub const temporary: win32.DWORD = 0x100;
    pub const delete_on_close: win32.DWORD = 0x0400_0000;
};

/// A new read-write file `leaf` in `area` of `session` that is gone once
/// closed. `PathAlreadyExists` when the name is in use.
pub fn open(session: *const Session, area: Area, leaf: []const u8) !std.Io.File {
    const io = session.base.io;
    _ = try name.component(leaf);
    var dir = try paths.area(session, if (area == .frames) .frames else .scratch);
    defer dir.close(io);
    if (builtin.os.tag == .windows) return openWindows(session, area, leaf);
    const file = try dir.createFile(io, leaf, .{ .read = true, .exclusive = true });
    errdefer file.close(io);
    try dir.deleteFile(io, leaf);
    return file;
}

fn openWindows(session: *const Session, area: Area, leaf: []const u8) !std.Io.File {
    const allocator = session.base.allocator;
    const unc = std.mem.startsWith(u8, session.base.path, "\\\\");
    const prefix: []const u8 = if (unc) "\\\\?\\UNC\\" else "\\\\?\\";
    const root_path = if (unc) session.base.path[2..] else session.base.path;
    const path = try std.fmt.allocPrint(allocator, "{s}{s}\\{s}\\{s}\\{s}", .{ prefix, root_path, &session.id, @tagName(area), leaf });
    defer allocator.free(path);
    const wide = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, path);
    defer allocator.free(wide);
    const handle = win32.CreateFileW(wide, access.generic_read_write, access.share_all, null, access.create_new, access.temporary | access.delete_on_close, null);
    if (handle == win32.invalid_handle) {
        return if (present(session, area, leaf)) error.PathAlreadyExists else error.ScratchOpenFailed;
    }
    return .{ .handle = handle, .flags = .{ .nonblocking = false } };
}

fn present(session: *const Session, area: Area, leaf: []const u8) bool {
    var buffer: [name.limits.component + 16]u8 = undefined;
    const sub = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ @tagName(area), leaf }) catch return false;
    session.dir.access(session.base.io, sub, .{}) catch return false;
    return true;
}
