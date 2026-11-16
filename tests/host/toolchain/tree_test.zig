//! Synthetic archive entries exercise the same sink as verified tar/zip bytes.
const std = @import("std");
const toolchain = @import("ra8").host.toolchain;
const Tree = toolchain.tree.Tree;

const Source = struct {
    bytes: []const u8,
    pub fn writeTo(self: Source, writer: *std.Io.Writer) !void {
        try writer.writeAll(self.bytes);
    }
};

fn file(tree: *Tree, name: []const u8, contents: []const u8) !void {
    try tree.accept(.{ .name = name, .kind = .file, .size = contents.len, .mode = 0o644 }, Source{ .bytes = contents });
}

test "a complete tree verifies against independent archive contents and rejects mutation" {
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try toolchain.ownership.makePrivate(std.testing.io, temp.dir);
    var tree = Tree.init(std.testing.allocator, std.testing.io, temp.dir, true, "zig-test");
    defer tree.deinit();
    try file(&tree, "zig-test/lib/sample.zig", "pub const x = 42;\n");
    try file(&tree, "zig-test/zig", "compiler");
    try tree.finish();
    var verifier = Tree.init(std.testing.allocator, std.testing.io, temp.dir, false, "zig-test");
    defer verifier.deinit();
    try file(&verifier, "zig-test/lib/sample.zig", "pub const x = 42;\n");
    try file(&verifier, "zig-test/zig", "compiler");
    try verifier.finish();
    try std.testing.expectEqualStrings(tree.manifest.items, verifier.manifest.items);
    var changed = Tree.init(std.testing.allocator, std.testing.io, temp.dir, false, "zig-test");
    defer changed.deinit();
    try std.testing.expectError(error.CacheIntegrityMismatch, file(&changed, "zig-test/lib/sample.zig", "pub const x = 43;\n"));
}

test "archive names reject traversal devices alternate streams and portable case collisions" {
    for ([_][]const u8{ "../outside", "/absolute", "zig-test/../outside", "zig-test/a:stream", "zig-test/con", "zig-test/a.", "zig-test/a ", "zig-test/a\\b" }) |name| {
        try std.testing.expectError(error.UnsafeArchivePath, toolchain.paths.name(name));
    }
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try toolchain.ownership.makePrivate(std.testing.io, temp.dir);
    var tree = Tree.init(std.testing.allocator, std.testing.io, temp.dir, true, "zig-test");
    defer tree.deinit();
    try file(&tree, "zig-test/Hello", "a");
    try std.testing.expectError(error.ArchiveCollision, file(&tree, "zig-test/hello", "a"));
    try std.testing.expectError(error.ArchiveCollision, file(&tree, "zig-test/Hello", "a"));
    try std.testing.expectError(error.WrongArchiveRoot, file(&tree, "other/tool", "a"));
}

test "unlisted files never become part of an admitted compiler tree" {
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try toolchain.ownership.makePrivate(std.testing.io, temp.dir);
    var tree = Tree.init(std.testing.allocator, std.testing.io, temp.dir, true, "zig-test");
    defer tree.deinit();
    try file(&tree, "zig-test/zig", "compiler");
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "extra", .data = "injected" });
    try std.testing.expectError(error.ExtraCacheEntry, tree.finish());
}

test "verification rejects a compiler file whose immutable permissions were cleared" {
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const io = std.testing.io;
    try toolchain.ownership.makePrivate(io, temp.dir);
    var tree = Tree.init(std.testing.allocator, io, temp.dir, true, "zig-test");
    defer tree.deinit();
    try file(&tree, "zig-test/zig", "compiler");
    try tree.finish();
    try makeMutable(temp.dir, "zig-test/zig");
    var verifier = Tree.init(std.testing.allocator, io, temp.dir, false, "zig-test");
    defer verifier.deinit();
    try std.testing.expectError(error.CacheIntegrityMismatch, file(&verifier, "zig-test/zig", "compiler"));
}

test "deep directory stack handles prefix switches and paths deeper than sixteen components" {
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const io = std.testing.io;
    try toolchain.ownership.makePrivate(io, temp.dir);
    const deep = "zig-test/a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p/q/r/s/leaf.txt";
    const mid = "zig-test/a/b/c/other.txt";
    var install_tree = Tree.init(std.testing.allocator, io, temp.dir, true, "zig-test");
    defer install_tree.deinit();
    try file(&install_tree, deep, "deep-body");
    try file(&install_tree, mid, "mid-body");
    try install_tree.finish();
    var verify_tree = Tree.init(std.testing.allocator, io, temp.dir, false, "zig-test");
    defer verify_tree.deinit();
    try file(&verify_tree, deep, "deep-body");
    try file(&verify_tree, mid, "mid-body");
    try verify_tree.finish();
    try std.testing.expectEqualStrings(install_tree.manifest.items, verify_tree.manifest.items);
}

fn makeMutable(dir: std.Io.Dir, name: []const u8) !void {
    const io = std.testing.io;
    if (@import("builtin").os.tag != .windows) {
        try dir.setFilePermissions(io, name, .fromMode(0o644), .{ .follow_symlinks = false });
        return;
    }
    // std.Io.Dir.setFilePermissions is not implemented on Windows yet.
    // This fixture-owned path is used only to mutate a test's own installed file.
    var buffer: [4096]u8 = undefined;
    const length = try dir.realPathFile(io, name, &buffer);
    const wide = try std.unicode.wtf8ToWtf16LeAllocZ(std.testing.allocator, buffer[0..length]);
    defer std.testing.allocator.free(wide);
    // FILE_ATTRIBUTE_NORMAL explicitly clears READONLY.
    try std.testing.expect(SetFileAttributesW(wide.ptr, 0x80).toBool());
}

extern "kernel32" fn SetFileAttributesW([*:0]const u16, u32) callconv(.winapi) std.os.windows.BOOL;
