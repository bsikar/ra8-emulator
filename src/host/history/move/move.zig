//! Non-overwriting moves of validated immediate children. Linux filesystems
//! may reject RENAME_NOREPLACE with EINVAL; report that capability failure
//! instead of invoking the standard backend's programmer-bug panic.
const std = @import("std");
const builtin = @import("builtin");
const name = @import("../root.zig").name;

pub fn preserve(io: std.Io, from_dir: std.Io.Dir, from: []const u8, to_dir: std.Io.Dir, to: []const u8) !void {
    _ = try name.component(from);
    _ = try name.component(to);
    if (builtin.os.tag != .linux) return from_dir.renamePreserve(from, to_dir, to, io);
    var source: [name.limits.component:0]u8 = @splat(0);
    var target: [name.limits.component:0]u8 = @splat(0);
    @memcpy(source[0..from.len], from);
    @memcpy(target[0..to.len], to);
    while (true) {
        const status = std.os.linux.errno(std.os.linux.renameat2(from_dir.handle, source[0..from.len :0], to_dir.handle, target[0..to.len :0], .{ .NOREPLACE = true }));
        switch (status) {
            .SUCCESS => return,
            .INTR => continue,
            .INVAL, .NOSYS, .OPNOTSUPP => return error.OperationUnsupported,
            .EXIST => return error.PathAlreadyExists,
            .NOENT => return error.FileNotFound,
            .XDEV => return error.CrossDevice,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .NOTDIR => return error.NotDir,
            .ISDIR => return error.IsDir,
            .NOTEMPTY => return error.DirNotEmpty,
            .ROFS => return error.ReadOnlyFileSystem,
            .NOSPC => return error.NoSpaceLeft,
            .DQUOT => return error.DiskQuota,
            .IO => return error.FileSystem,
            else => return error.Unexpected,
        }
    }
}
