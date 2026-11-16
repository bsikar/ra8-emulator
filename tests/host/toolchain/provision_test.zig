//! Managed generations cannot reside in an RPC-writable workspace.
const builtin = @import("builtin");
const std = @import("std");

const provision = @import("ra8").host.toolchain.provision;
const ownership = @import("ra8").host.toolchain.ownership;

fn absolute(dir: std.Io.Dir, buffer: []u8) ![]const u8 {
    return buffer[0..try dir.realPath(std.testing.io, buffer)];
}

fn protectedTemp() !std.testing.TmpDir {
    if (builtin.os.tag != .windows) return std.testing.tmpDir(.{});
    var wide: [4096]u16 = undefined;
    const name = std.unicode.wtf8ToWtf16LeStringLiteral("LOCALAPPDATA");
    const length = GetEnvironmentVariableW(name, &wide, wide.len);
    if (length == 0 or length >= wide.len) return error.LocalAppDataUnavailable;
    const profile = try std.unicode.wtf16LeToWtf8Alloc(std.testing.allocator, wide[0..length]);
    defer std.testing.allocator.free(profile);
    const io = std.testing.io;
    const parent = try std.Io.Dir.openDirAbsolute(io, profile, .{ .follow_symlinks = false });
    errdefer parent.close(io);
    var random: [8]u8 = undefined;
    io.random(&random);
    const leaf = std.fmt.bytesToHex(random, .lower);
    try parent.createDir(io, &leaf, .default_dir);
    errdefer parent.deleteTree(io, &leaf) catch {};
    const dir = try parent.openDir(io, &leaf, .{ .follow_symlinks = false });
    errdefer dir.close(io);
    try ownership.makePrivate(io, dir);
    return .{ .dir = dir, .parent_dir = parent, .sub_path = leaf };
}

extern "kernel32" fn GetEnvironmentVariableW([*:0]const u16, [*]u16, u32) callconv(.winapi) u32;

test "canonical managed cache and workspace must be disjoint in both directions" {
    var temp = try protectedTemp();
    defer temp.cleanup();
    try ownership.makePrivate(std.testing.io, temp.dir);
    try temp.dir.createDir(std.testing.io, "workspace", .default_dir);
    try temp.dir.createDir(std.testing.io, "cache", .default_dir);
    const workspace = try temp.dir.openDir(std.testing.io, "workspace", .{});
    defer workspace.close(std.testing.io);
    try ownership.makePrivate(std.testing.io, workspace);
    const cache = try temp.dir.openDir(std.testing.io, "cache", .{});
    defer cache.close(std.testing.io);
    try ownership.makePrivate(std.testing.io, cache);
    var root_buffer: [4096]u8 = undefined;
    var workspace_buffer: [4096]u8 = undefined;
    var cache_buffer: [4096]u8 = undefined;
    const root_path = try absolute(temp.dir, &root_buffer);
    const workspace_path = try absolute(workspace, &workspace_buffer);
    const cache_path = try absolute(cache, &cache_buffer);
    try provision.separate(std.testing.io, workspace, cache_path);
    try std.testing.expectError(error.CacheWorkspaceOverlap, provision.separate(std.testing.io, workspace, workspace_path));
    try std.testing.expectError(error.CacheWorkspaceOverlap, provision.separate(std.testing.io, temp.dir, cache_path));
    try std.testing.expectError(error.CacheWorkspaceOverlap, provision.separate(std.testing.io, workspace, root_path));
}

test "explicit absolute compiler symlinks resolve once and invalid winners never fall back" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try ownership.makePrivate(std.testing.io, temp.dir);
    try temp.dir.symLink(io, @import("test_paths").compiler, "compiler", .{});
    var buffer: [4096]u8 = undefined;
    const root = try absolute(temp.dir, &buffer);
    const link = try std.fs.path.join(std.testing.allocator, &.{ root, "compiler" });
    defer std.testing.allocator.free(link);
    const selected = try provision.resolve(std.testing.allocator, io, .{
        .host = try provision.nativeHost(),
        .target = "ra8d2",
        .project_zig = link,
    });
    defer std.testing.allocator.free(selected.compiler_path);
    var canonical_buffer: [4096]u8 = undefined;
    const count = try std.Io.Dir.cwd().realPathFile(io, @import("test_paths").compiler, &canonical_buffer);
    try std.testing.expectEqualStrings(canonical_buffer[0..count], selected.compiler_path);
    try temp.dir.deleteFile(io, "compiler");
    try temp.dir.symLink(io, "/does-not-exist/compiler", "compiler", .{});
    try std.testing.expectError(error.FileNotFound, provision.resolve(std.testing.allocator, io, .{
        .host = try provision.nativeHost(),
        .target = "ra8d2",
        .project_zig = link,
        .backend_zig = @import("test_paths").compiler,
    }));
}
