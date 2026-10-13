//! Non-overwriting move of one closed regular file on Linux mounts that
//! reject RENAME_NOREPLACE: the file is given its new name by a link, which
//! the kernel refuses when anything has that name, and the old name is
//! taken away only while the new one is seen to be the same file. So no
//! entry is ever replaced and no byte is ever without a name.
//!
//! A lease is never moved this way: a second name of a file can carry a
//! lock of its own. Only closed payload and marker files are.

const std = @import("std");
const builtin = @import("builtin");
const name = @import("../root.zig").name;
const linux = std.os.linux;
const hooks = @import("probe.zig");

pub const Kind = enum { file, directory, other };

/// What an entry is now. Two names seen with one device and inode at the
/// same moment are one file; nothing here is kept across a restart.
pub const State = struct {
    device_major: u32,
    device_minor: u32,
    inode: u64,
    links: u32,
    kind: Kind,

    pub fn same(a: State, b: State) bool {
        return a.device_major == b.device_major and a.device_minor == b.device_minor and a.inode == b.inode and a.kind == b.kind;
    }
};

const Leaf = [name.limits.component:0]u8;

/// Move the file `from` to `to`. `PathAlreadyExists` for any entry at `to`,
/// whatever its kind, and then nothing has changed.
pub fn carry(from_dir: std.Io.Dir, from: []const u8, to_dir: std.Io.Dir, to: []const u8) anyerror!void {
    return carryProbed(from_dir, from, to_dir, to, null);
}

pub fn carryProbed(from_dir: std.Io.Dir, from: []const u8, to_dir: std.Io.Dir, to: []const u8, probe: ?hooks.Probe) anyerror!void {
    const source = try state(from_dir, from);
    if (source.kind != .file) return error.UnexpectedKind;
    if (source.links != 1) return error.UnexpectedLinkCount;
    try link(from_dir, from, to_dir, to);
    try syncDir(to_dir);
    try hooks.reach(probe, .file_linked, from_dir, from, to_dir, to);
    try finish(from_dir, from, to_dir, to);
    try hooks.reach(probe, .file_unlinked, from_dir, from, to_dir, to);
}

/// Carry on with a move that may have been killed between its link and its
/// unlink. `IdentityConflict` when `to` is some other file; both stay.
pub fn settle(from_dir: std.Io.Dir, from: []const u8, to_dir: std.Io.Dir, to: []const u8) anyerror!void {
    return settleProbed(from_dir, from, to_dir, to, null);
}

pub fn settleProbed(from_dir: std.Io.Dir, from: []const u8, to_dir: std.Io.Dir, to: []const u8, probe: ?hooks.Probe) anyerror!void {
    const source = try state(from_dir, from);
    const target = state(to_dir, to) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (target) |found| {
        if (!source.same(found)) return error.IdentityConflict;
    } else return carryProbed(from_dir, from, to_dir, to, probe);
    try finish(from_dir, from, to_dir, to);
    try hooks.reach(probe, .file_unlinked, from_dir, from, to_dir, to);
}

/// Take `from` away, and only while `to` is the same file.
pub fn finish(from_dir: std.Io.Dir, from: []const u8, to_dir: std.Io.Dir, to: []const u8) anyerror!void {
    if (builtin.os.tag != .linux) return error.OperationUnsupported;
    const source = try state(from_dir, from);
    const target = try state(to_dir, to);
    if (source.kind != .file or !source.same(target)) return error.IdentityConflict;
    if (source.links != 2 or target.links != 2) return error.UnexpectedLinkCount;
    var buffer: Leaf = undefined;
    const path = try terminated(&buffer, from);
    while (true) switch (linux.errno(linux.unlinkat(from_dir.handle, path, 0))) {
        .SUCCESS => return syncDir(from_dir),
        .INTR => continue,
        else => |status| return failure(status),
    };
}

/// The state of `leaf`, never following a link. `FileNotFound` when absent.
pub fn state(dir: std.Io.Dir, leaf: []const u8) anyerror!State {
    if (builtin.os.tag != .linux) return error.OperationUnsupported;
    var buffer: Leaf = undefined;
    return read(dir.handle, try terminated(&buffer, leaf), linux.AT.SYMLINK_NOFOLLOW);
}

/// The state of the open directory `dir` itself.
pub fn here(dir: std.Io.Dir) anyerror!State {
    if (builtin.os.tag != .linux) return error.OperationUnsupported;
    return read(dir.handle, "", linux.AT.EMPTY_PATH);
}

pub fn opened(handle: std.Io.File) !State {
    if (builtin.os.tag != .linux) return error.OperationUnsupported;
    return read(handle.handle, "", linux.AT.EMPTY_PATH);
}

pub fn syncDir(dir: std.Io.Dir) !void {
    if (builtin.os.tag != .linux) return error.OperationUnsupported;
    while (true) switch (linux.errno(linux.fsync(dir.handle))) {
        .SUCCESS => return,
        .INTR => continue,
        else => |status| return failure(status),
    };
}

fn read(fd: std.posix.fd_t, path: [*:0]const u8, flags: u32) anyerror!State {
    var stat: linux.Statx = undefined;
    while (true) switch (linux.errno(linux.statx(fd, path, flags, .{ .TYPE = true, .INO = true, .NLINK = true }, &stat))) {
        .SUCCESS => break,
        .INTR => continue,
        else => |status| return failure(status),
    };
    if (!stat.mask.TYPE or !stat.mask.INO or !stat.mask.NLINK) return error.IdentityUnsupported;
    const kind: Kind = switch (stat.mode & linux.S.IFMT) {
        linux.S.IFREG => .file,
        linux.S.IFDIR => .directory,
        else => .other,
    };
    return .{ .device_major = stat.dev_major, .device_minor = stat.dev_minor, .inode = stat.ino, .links = stat.nlink, .kind = kind };
}

/// Give the file `from` the second name `to`. `PathAlreadyExists` for any
/// entry at `to`.
pub fn link(from_dir: std.Io.Dir, from: []const u8, to_dir: std.Io.Dir, to: []const u8) anyerror!void {
    if (builtin.os.tag != .linux) return error.OperationUnsupported;
    var source: Leaf = undefined;
    var target: Leaf = undefined;
    const old = try terminated(&source, from);
    const new = try terminated(&target, to);
    const before = try state(from_dir, from);
    if (before.kind != .file or before.links != 1) return error.UnexpectedKind;
    const fd = while (true) {
        const result = linux.openat(from_dir.handle, old, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true }, 0);
        const status = linux.errno(result);
        if (status == .SUCCESS) break @as(linux.fd_t, @intCast(result));
        if (status != .INTR) return failure(status);
    };
    defer _ = linux.close(fd);
    const bound = try read(fd, "", linux.AT.EMPTY_PATH);
    if (!before.same(bound) or bound.links != 1) return error.IdentityConflict;
    while (true) switch (linux.errno(linux.linkat(fd, "", to_dir.handle, new, linux.AT.EMPTY_PATH))) {
        .SUCCESS => return,
        .INTR => continue,
        .EXIST => return error.PathAlreadyExists,
        else => |status| return failure(status),
    };
}

fn terminated(buffer: *Leaf, leaf: []const u8) ![:0]const u8 {
    _ = try name.component(leaf);
    buffer.* = @splat(0);
    @memcpy(buffer[0..leaf.len], leaf);
    return buffer[0..leaf.len :0];
}

fn failure(status: linux.E) anyerror {
    return switch (status) {
        .NOENT => error.FileNotFound,
        .XDEV => error.CrossDevice,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .BUSY => error.FileBusy,
        .NOTDIR => error.NotDir,
        .LOOP => error.SymLinkLoop,
        .MLINK => error.LinkQuotaExceeded,
        .ROFS => error.ReadOnlyFileSystem,
        .NOSPC => error.NoSpaceLeft,
        .DQUOT => error.DiskQuota,
        .IO => error.FileSystem,
        else => error.Unexpected,
    };
}
