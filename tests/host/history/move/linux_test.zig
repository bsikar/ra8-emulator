//! The Linux primitives of the shared native move peer driver (peer.zig).
const std = @import("std");
const builtin = @import("builtin");
const linux = @import("ra8").host.history.move.linux;
const wire = @import("ra8").host.history.move.wire;
const layout = @import("ra8").host.history.layout;

test "linux pinRoot refuses a relative root path" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try std.testing.expectError(error.UnsupportedRoot, linux.pinRoot(std.testing.allocator, std.testing.io, .{ .path = "relative", .marker = layout.root.marker_text }));
}

test "linux pin and rename move a child no-replace and report a collision" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(io, "src/child");
    try tmp.dir.makePath(io, "dst");
    const source_root = try linux.pin(allocator, io, tmp.dir, "src", false);
    defer source_root.close(io);
    const target_root = try linux.pin(allocator, io, tmp.dir, "dst", false);
    defer target_root.close(io);
    const child = try linux.pin(allocator, io, source_root, "child", true);
    defer child.close(io);
    try std.testing.expectEqual(wire.Status.success, try linux.rename(allocator, child, target_root, "moved"));
    var moved = try target_root.openDir(io, "moved", .{});
    defer moved.close(io);
    try tmp.dir.makePath(io, "src/child");
    const second = try linux.pin(allocator, io, source_root, "child", true);
    defer second.close(io);
    try std.testing.expectEqual(wire.Status.collision, try linux.rename(allocator, second, target_root, "moved"));
}

test "linux birth reports a nonzero process creation time" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try std.testing.expect(try linux.birth(std.testing.io) > 0);
}

test "linux leafPath passes the native path through unchanged" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const path = try linux.leafPath(allocator, "/mnt/c/store/child");
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/mnt/c/store/child", path);
}
