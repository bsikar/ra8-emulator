const builtin = @import("builtin");
const std = @import("std");
const ownership = @import("ra8").host.toolchain.ownership;

const w = std.os.windows;

test "private permissions reopen a non-iterable pinned directory after rename" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDir(io, "original", .fromMode(0o755));
    const pinned = try temp.dir.openDir(io, "original", .{ .follow_symlinks = false });
    defer pinned.close(io);
    try temp.dir.rename("original", temp.dir, "moved", io);
    try temp.dir.createDir(io, "original", .fromMode(0o755));
    const before = try temp.dir.statFile(io, "original", .{ .follow_symlinks = false });
    try ownership.makePrivate(io, pinned);
    try std.testing.expectEqual(@as(u32, 0o700), (try pinned.stat(io)).permissions.toMode() & 0o777);
    const decoy = try temp.dir.statFile(io, "original", .{ .follow_symlinks = false });
    try std.testing.expectEqual(before.permissions.toMode(), decoy.permissions.toMode());
}

test "ownership policy refuses different owner and every other write bit" {
    try ownership.posix(42, 42, 0o755);
    try std.testing.expectError(error.UnsafeCacheOwnership, ownership.posix(43, 42, 0o700));
    try std.testing.expectError(error.UnsafeCacheOwnership, ownership.posix(42, 42, 0o720));
    try std.testing.expectError(error.UnsafeCacheOwnership, ownership.posix(42, 42, 0o702));
}

test "cache directory and file permissions are checked on the open objects" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const io = std.testing.io;
    try ownership.makePrivate(io, temp.dir);
    try temp.dir.setPermissions(io, .fromMode(0o755));
    try ownership.directory(io, temp.dir);
    try temp.dir.setPermissions(io, .fromMode(0o777));
    try std.testing.expectError(error.UnsafeCacheOwnership, ownership.directory(io, temp.dir));
    try ownership.makePrivate(io, temp.dir);
    const opened = try temp.dir.createFile(io, "compiler", .{ .permissions = .fromMode(0o600) });
    defer opened.close(io);
    try ownership.file(io, opened);
    try opened.setPermissions(io, .fromMode(0o620));
    try std.testing.expectError(error.UnsafeCacheOwnership, ownership.file(io, opened));
}

test "Windows private ACL accepts inherited files and refuses null and broad write DACLs" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const io = std.testing.io;
    try ownership.makePrivate(io, temp.dir);
    {
        const opened = try temp.dir.createFile(io, "compiler", .{ .read = true });
        defer opened.close(io);
        try ownership.makeFilePrivate(io, temp.dir, "compiler", opened);
        try ownership.file(io, opened);
    }
    try temp.dir.deleteFile(io, "compiler");
    const handle = try ownership.Windows.editDirectory(temp.dir.handle, false);
    try std.testing.expect(handle != w.INVALID_HANDLE_VALUE);
    defer _ = w.ntdll.NtClose(handle);
    try std.testing.expectEqual(@as(u32, 0), SetSecurityInfo(handle, 1, 0x80000004, null, null, null, null));
    try std.testing.expectError(error.UnsafeCacheOwnership, ownership.directory(io, temp.dir));
    try ownership.makePrivate(io, temp.dir);
    var bytes: [128]u8 align(4) = undefined;
    var everyone: [68]u8 align(4) = undefined;
    var size: u32 = everyone.len;
    try std.testing.expect(CreateWellKnownSid(1, null, &everyone, &size).toBool());
    try std.testing.expect(InitializeAcl(&bytes, bytes.len, 2).toBool());
    try std.testing.expect(AddAccessAllowedAceEx(&bytes, 2, 3, 0x001F01FF, &everyone).toBool());
    try std.testing.expectEqual(@as(u32, 0), SetSecurityInfo(handle, 1, 0x80000004, null, null, &bytes, null));
    try std.testing.expectError(error.UnsafeCacheOwnership, ownership.directory(io, temp.dir));
    try ownership.makePrivate(io, temp.dir);
    try ownership.directory(io, temp.dir);
}

extern "advapi32" fn SetSecurityInfo(
    w.HANDLE,
    u32,
    u32,
    ?*anyopaque,
    ?*anyopaque,
    ?*anyopaque,
    ?*anyopaque,
) callconv(.winapi) u32;
extern "advapi32" fn CreateWellKnownSid(u32, ?*anyopaque, *anyopaque, *u32) callconv(.winapi) w.BOOL;
extern "advapi32" fn InitializeAcl(*anyopaque, u32, u32) callconv(.winapi) w.BOOL;
extern "advapi32" fn AddAccessAllowedAceEx(*anyopaque, u32, u32, u32, *anyopaque) callconv(.winapi) w.BOOL;

test "ancestor policy protects renames while accepting trusted sticky temporary directories" {
    try ownership.posixAncestor(0, 42, 0o755);
    try ownership.posixAncestor(0, 42, 0o1777);
    try ownership.posixAncestor(42, 42, 0o1777);
    try std.testing.expectError(error.UnsafeCacheOwnership, ownership.posixAncestor(0, 42, 0o777));
    try std.testing.expectError(error.UnsafeCacheOwnership, ownership.posixAncestor(43, 42, 0o1777));
    try std.testing.expectError(error.UnsafeCacheOwnership, ownership.posixAncestor(43, 42, 0o755));
    if (builtin.os.tag == .windows) return;
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try temp.dir.setPermissions(std.testing.io, .fromMode(0o1777));
    try ownership.ancestor(std.testing.io, temp.dir);
    try std.testing.expectError(error.UnsafeCacheOwnership, ownership.directory(std.testing.io, temp.dir));
}

test "Windows ancestors allow creation only and reject every unrelated mutation right" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try ownership.makePrivate(std.testing.io, temp.dir);
    const handle = try ownership.Windows.editDirectory(temp.dir.handle, false);
    try std.testing.expect(handle != w.INVALID_HANDLE_VALUE);
    defer _ = w.ntdll.NtClose(handle);
    // The retained handle lets this test restore its own directory's ACL even
    // after deliberately removing the owner's explicit access grants.
    defer _ = SetSecurityInfo(handle, 1, 0x80000004, null, null, null, null);
    try everyoneAcl(handle, 4, 0);
    try ownership.ancestor(std.testing.io, temp.dir);
    try std.testing.expectError(error.UnsafeCacheOwnership, ownership.directory(std.testing.io, temp.dir));
    for ([_]u32{ 2, 0x10, 0x40, 0x100, 0x10000, 0x40000, 0x80000, 0x40000000 }) |mask| {
        try everyoneAcl(handle, mask, 0);
        try std.testing.expectError(error.UnsafeCacheOwnership, ownership.ancestor(std.testing.io, temp.dir));
    }
    try everyoneAcl(handle, 0x001F01FF, 11);
    try ownership.ancestor(std.testing.io, temp.dir);
    try std.testing.expectError(error.UnsafeCacheOwnership, ownership.directory(std.testing.io, temp.dir));
    try std.testing.expectEqual(@as(u32, 0), SetSecurityInfo(handle, 1, 0x80000004, null, null, null, null));
    try ownership.makePrivate(std.testing.io, temp.dir);
}

fn everyoneAcl(handle: w.HANDLE, mask: u32, flags: u32) !void {
    var bytes: [128]u8 align(4) = undefined;
    var everyone: [68]u8 align(4) = undefined;
    var size: u32 = everyone.len;
    try std.testing.expect(CreateWellKnownSid(1, null, &everyone, &size).toBool());
    try std.testing.expect(InitializeAcl(&bytes, bytes.len, 2).toBool());
    try std.testing.expect(AddAccessAllowedAceEx(&bytes, 2, flags, mask, &everyone).toBool());
    try std.testing.expectEqual(@as(u32, 0), SetSecurityInfo(handle, 1, 0x80000004, null, null, &bytes, null));
}

test "Windows security edits stay on a pinned directory after rename and replacement" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const io = std.testing.io;
    try ownership.makePrivate(io, temp.dir);
    try temp.dir.createDir(io, "original", .default_dir);
    const original = try temp.dir.openDir(io, "original", .{ .iterate = true, .follow_symlinks = false });
    defer original.close(io);
    const inode = (try original.stat(io)).inode;
    try temp.dir.rename("original", temp.dir, "moved", io);
    try temp.dir.createDir(io, "original", .default_dir);
    const decoy = try temp.dir.openDir(io, "original", .{ .iterate = true, .follow_symlinks = false });
    defer decoy.close(io);
    const editable = try ownership.Windows.editDirectory(decoy.handle, false);
    defer _ = w.ntdll.NtClose(editable);
    try std.testing.expectEqual(@as(u32, 0), SetSecurityInfo(editable, 1, 0x80000004, null, null, null, null));
    try ownership.makePrivate(io, original);
    try std.testing.expectEqual(inode, (try original.stat(io)).inode);
    try ownership.directory(io, original);
    try std.testing.expectError(error.UnsafeCacheOwnership, ownership.directory(io, decoy));
}

test "Windows new file ownership refuses an entry different from the exclusive creation handle" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const io = std.testing.io;
    try ownership.makePrivate(io, temp.dir);
    const first = try temp.dir.createFile(io, "first", .{ .read = true, .exclusive = true });
    defer first.close(io);
    const second = try temp.dir.createFile(io, "second", .{ .read = true, .exclusive = true });
    defer second.close(io);
    try std.testing.expectError(error.UnsafeCacheOwnership, ownership.makeFilePrivate(io, temp.dir, "second", first));
    try ownership.makeFilePrivate(io, temp.dir, "first", first);
    try ownership.file(io, first);
}
