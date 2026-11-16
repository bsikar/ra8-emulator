//! Exercise real zip streaming across File.Reader buffer boundaries and attribute refusals.
const std = @import("std");

const toolchain = @import("ra8").host.toolchain;

const ZipEntry = struct {
    name: []const u8,
    data: []const u8,
    attrs: u32 = 0o100644 << 16,
};

fn writeInt(list: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try list.appendSlice(allocator, &bytes);
}

fn buildZip(allocator: std.mem.Allocator, items: []const ZipEntry) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var cd: std.ArrayList(u8) = .empty;
    defer cd.deinit(allocator);
    for (items) |item| {
        const offset: u32 = @intCast(out.items.len);
        const crc = std.hash.Crc32.hash(item.data);
        const size: u32 = @intCast(item.data.len);
        const name_len: u16 = @intCast(item.name.len);
        try out.appendSlice(allocator, &.{ 'P', 'K', 3, 4 });
        for ([_]u16{ 20, 0, 0, 0, 0 }) |field| try writeInt(&out, allocator, u16, field);
        for ([_]u32{ crc, size, size }) |field| try writeInt(&out, allocator, u32, field);
        try writeInt(&out, allocator, u16, name_len);
        try writeInt(&out, allocator, u16, 0);
        try out.appendSlice(allocator, item.name);
        try out.appendSlice(allocator, item.data);
        try cd.appendSlice(allocator, &.{ 'P', 'K', 1, 2 });
        for ([_]u16{ 0x031e, 20, 0, 0, 0, 0 }) |field| try writeInt(&cd, allocator, u16, field);
        for ([_]u32{ crc, size, size }) |field| try writeInt(&cd, allocator, u32, field);
        for ([_]u16{ name_len, 0, 0, 0, 0 }) |field| try writeInt(&cd, allocator, u16, field);
        try writeInt(&cd, allocator, u32, item.attrs);
        try writeInt(&cd, allocator, u32, offset);
        try cd.appendSlice(allocator, item.name);
    }
    const cd_offset: u32 = @intCast(out.items.len);
    const cd_size: u32 = @intCast(cd.items.len);
    try out.appendSlice(allocator, cd.items);
    try out.appendSlice(allocator, &.{ 'P', 'K', 5, 6 });
    for ([_]u16{ 0, 0, @intCast(items.len), @intCast(items.len) }) |field| try writeInt(&out, allocator, u16, field);
    try writeInt(&out, allocator, u32, cd_size);
    try writeInt(&out, allocator, u32, cd_offset);
    try writeInt(&out, allocator, u16, 0);
    return out.toOwnedSlice(allocator);
}

test "zip walk handles stored entries past reader buffer boundaries and admits installed tree" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const large = try allocator.alloc(u8, 70_000);
    defer allocator.free(large);
    @memset(large, 'Z');
    const small = "stored entry past 64KiB buffer boundary so streamMode uses positional_simple\n";
    const bytes = try buildZip(allocator, &.{
        .{ .name = "zig-test/large.bin", .data = large },
        .{ .name = "zig-test/sub/", .data = "", .attrs = 0o040755 << 16 },
        .{ .name = "zig-test/sub/small.bin", .data = small },
        .{ .name = "zig-test/sibling.txt", .data = "back to parent\n" },
    });
    defer allocator.free(bytes);
    const hash = toolchain.digest.bytes(bytes);
    const artifact: toolchain.artifact.Artifact = .{
        .host = "x86_64-windows",
        .url = "https://example.invalid/zig-test.zip",
        .sha256 = &hash,
        .archive_bytes = bytes.len,
        .executable = "zig-test/zig.exe",
    };

    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try toolchain.ownership.makePrivate(io, temp.dir);
    try temp.dir.writeFile(io, .{ .sub_path = ".archive", .data = bytes });
    const file = try temp.dir.openFile(io, ".archive", .{ .follow_symlinks = false });
    defer file.close(io);

    var install_tree = toolchain.tree.Tree.init(allocator, io, temp.dir, true, "zig-test");
    defer install_tree.deinit();
    try toolchain.archive.walk(file, artifact, &install_tree);
    var verify_tree = toolchain.tree.Tree.init(allocator, io, temp.dir, false, "zig-test");
    defer verify_tree.deinit();
    try toolchain.archive.walk(file, artifact, &verify_tree);
    try std.testing.expectEqualStrings(install_tree.manifest.items, verify_tree.manifest.items);
}

test "archive verify and walk reject tampered bytes symlinks reparse attributes and mismatched directories" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const clean = try buildZip(allocator, &.{.{ .name = "zig-test/file.txt", .data = "ok" }});
    defer allocator.free(clean);
    const clean_hash = toolchain.digest.bytes(clean);
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try toolchain.ownership.makePrivate(io, temp.dir);
    try temp.dir.writeFile(io, .{ .sub_path = ".archive", .data = clean });
    const file = try temp.dir.openFile(io, ".archive", .{ .follow_symlinks = false });
    defer file.close(io);
    try std.testing.expectError(error.ArchiveSizeMismatch, toolchain.archive.verify(io, file, .{
        .host = "x86_64-windows",
        .url = "https://example.invalid/zig-test.zip",
        .sha256 = &clean_hash,
        .archive_bytes = clean.len + 1,
        .executable = "zig-test/zig.exe",
    }));
    const bad_hash: [64]u8 = @splat('0');
    try std.testing.expectError(error.ArchiveHashMismatch, toolchain.archive.verify(io, file, .{
        .host = "x86_64-windows",
        .url = "https://example.invalid/zig-test.zip",
        .sha256 = &bad_hash,
        .archive_bytes = clean.len,
        .executable = "zig-test/zig.exe",
    }));

    for ([_]struct { name: []const u8, attrs: u32, err: anyerror }{
        .{ .name = "zig-test/link", .attrs = 0o120777 << 16, .err = error.ArchiveLinkRefused },
        .{ .name = "zig-test/reparse", .attrs = (0o100644 << 16) | 0x400, .err = error.ArchiveLinkRefused },
        .{ .name = "zig-test/bad-dir/", .attrs = 0o100644 << 16, .err = error.BadArchiveDirectory },
        .{ .name = "zig-test/bad-file", .attrs = 0o040755 << 16, .err = error.BadArchiveDirectory },
    }, 0..) |case, idx| {
        const bad = try buildZip(allocator, &.{.{ .name = case.name, .data = "", .attrs = case.attrs }});
        defer allocator.free(bad);
        const bad_digest = toolchain.digest.bytes(bad);
        var name_buf: [16]u8 = undefined;
        const zip_name = try std.fmt.bufPrint(&name_buf, "bad-{d}.zip", .{idx});
        try temp.dir.writeFile(io, .{ .sub_path = zip_name, .data = bad });
        const bad_file = try temp.dir.openFile(io, zip_name, .{ .follow_symlinks = false });
        defer bad_file.close(io);
        var tree = toolchain.tree.Tree.init(allocator, io, temp.dir, false, "zig-test");
        defer tree.deinit();
        try std.testing.expectError(case.err, toolchain.archive.walk(bad_file, .{
            .host = "x86_64-windows",
            .url = "https://example.invalid/zig-test.zip",
            .sha256 = &bad_digest,
            .archive_bytes = bad.len,
            .executable = "zig-test/zig.exe",
        }, &tree));
    }
}
