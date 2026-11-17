//! Verify pinned manifest admission without re-decompressing healthy archives.
const std = @import("std");

const toolchain = @import("ra8").host.toolchain;
const Tree = toolchain.tree.Tree;

const Source = struct {
    bytes: []const u8,

    pub fn writeTo(self: Source, writer: *std.Io.Writer) !void {
        try writer.writeAll(self.bytes);
    }
};

fn buildTree(io: std.Io, root: std.Io.Dir) ![]u8 {
    var tree = Tree.init(std.testing.allocator, io, root, true, "zig-test");
    defer tree.deinit();
    try tree.accept(.{
        .name = "zig-test/lib/std/std.zig",
        .kind = .file,
        .size = 18,
        .mode = 0o644,
    }, Source{ .bytes = "pub const x = 42;\n" });
    try tree.accept(.{
        .name = "zig-test/zig",
        .kind = .file,
        .size = 8,
        .mode = 0o755,
    }, Source{ .bytes = "compiler" });
    try tree.finish();
    return try std.testing.allocator.dupe(u8, tree.manifest.items);
}

test "pinned manifest verification checks installed bytes permissions extras and manifest hash" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try toolchain.ownership.makePrivate(io, temp.dir);
    const bytes = try buildTree(io, temp.dir);
    defer std.testing.allocator.free(bytes);
    const expected = toolchain.digest.bytes(bytes);

    var ok = Tree.init(std.testing.allocator, io, temp.dir, false, "zig-test");
    defer ok.deinit();
    try toolchain.manifest.verify(bytes, &expected, &ok);
    try std.testing.expectEqual(@as(u32, 2), ok.entries);
    try std.testing.expectEqual(@as(u64, 26), ok.bytes);

    var bad_hash = expected;
    bad_hash[0] = if (bad_hash[0] == 'a') 'b' else 'a';
    var wrong_digest = Tree.init(std.testing.allocator, io, temp.dir, false, "zig-test");
    defer wrong_digest.deinit();
    try std.testing.expectError(
        error.CacheManifestMismatch,
        toolchain.manifest.verify(bytes, &bad_hash, &wrong_digest),
    );

    const malformed_line =
        "999 8 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa zig-test/zig\n";
    const malformed_sha = toolchain.digest.bytes(malformed_line);
    var malformed = Tree.init(std.testing.allocator, io, temp.dir, false, "zig-test");
    defer malformed.deinit();
    try std.testing.expectError(
        error.CacheManifestMismatch,
        toolchain.manifest.verify(malformed_line, &malformed_sha, &malformed),
    );

    try temp.dir.writeFile(io, .{ .sub_path = "zig-test/extra", .data = "injected" });
    var extra = Tree.init(std.testing.allocator, io, temp.dir, false, "zig-test");
    defer extra.deinit();
    try std.testing.expectError(
        error.ExtraCacheEntry,
        toolchain.manifest.verify(bytes, &expected, &extra),
    );
    try temp.dir.deleteFile(io, "zig-test/extra");

    try makeMutable(temp.dir, "zig-test/lib/std/std.zig");
    try temp.dir.writeFile(io, .{ .sub_path = "zig-test/lib/std/std.zig", .data = "pub const x = 43;\n" });
    var tampered = Tree.init(std.testing.allocator, io, temp.dir, false, "zig-test");
    defer tampered.deinit();
    try std.testing.expectError(
        error.CacheIntegrityMismatch,
        toolchain.manifest.verify(bytes, &expected, &tampered),
    );
}

fn makeMutable(dir: std.Io.Dir, name: []const u8) !void {
    const io = std.testing.io;
    if (@import("builtin").os.tag != .windows) {
        try dir.setFilePermissions(io, name, .fromMode(0o644), .{ .follow_symlinks = false });
        return;
    }
    var buffer: [4096]u8 = undefined;
    const length = try dir.realPathFile(io, name, &buffer);
    const wide = try std.unicode.wtf8ToWtf16LeAllocZ(std.testing.allocator, buffer[0..length]);
    defer std.testing.allocator.free(wide);
    try std.testing.expect(SetFileAttributesW(wide.ptr, 0x80).toBool());
}

extern "kernel32" fn SetFileAttributesW([*:0]const u16, u32) callconv(.winapi) std.os.windows.BOOL;
