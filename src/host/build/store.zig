//! Exclusive per-job output and evidence directories, never a shared zig-out.
const std = @import("std");
pub const Store = struct {
    dir: std.Io.Dir,
    relative: [44]u8,
    pub fn open(root: std.Io.Dir, io: std.Io) !Store {
        root.createDir(io, ".ra8-builds", .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const base = try root.openDir(io, ".ra8-builds", .{ .follow_symlinks = false });
        defer base.close(io);
        var random: [16]u8 = undefined;
        io.random(&random);
        const name = std.fmt.bytesToHex(random, .lower);
        try base.createDir(io, &name, .default_dir);
        const dir = try base.openDir(io, &name, .{ .follow_symlinks = false });
        errdefer dir.close(io);
        try dir.createDir(io, "out", .default_dir);
        var relative: [44]u8 = undefined;
        @memcpy(relative[0..12], ".ra8-builds/");
        @memcpy(relative[12..], &name);
        return .{ .dir = dir, .relative = relative };
    }
};

pub fn hostname(allocator: std.mem.Allocator) ![]const u8 {
    if (@import("builtin").os.tag == .windows) {
        var name: [256]u16 = undefined;
        var length: u32 = name.len;
        if (!@import("../win32.zig").GetComputerNameW(&name, &length).toBool()) return error.HostIdentityUnavailable;
        return std.unicode.utf16LeToUtf8Alloc(allocator, name[0..length]);
    }
    var name: [std.posix.HOST_NAME_MAX]u8 = undefined;
    return allocator.dupe(u8, try std.posix.gethostname(&name));
}
