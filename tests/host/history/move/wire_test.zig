const std = @import("std");
const ra8 = @import("ra8");
const wire = ra8.host.history.move.wire;
const io = std.testing.io;

test "native move translation permits only local drive roots" {
    const path = try wire.windowsPath(std.testing.allocator, "/mnt/c/Users/owner/cache");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("C:\\Users\\owner\\cache", path);
    for ([_][]const u8{ "/tmp/cache", "/mnt/c", "/mnt/cc/cache", "C:\\cache", "/mnt/C/cache" }) |bad| try std.testing.expectError(error.UnsupportedRoot, wire.windowsPath(std.testing.allocator, bad));
}

test "native pipe framing rejects oversized and truncated frames before parsing" {
    for ([_][]const u8{ &.{ 255, 255, 255, 255 }, &.{ 4, 0, 0, 0, '{' } }) |bytes| {
        const ends = try ra8.host.pipe_pair.create(.{});
        const input: std.Io.File = .{ .handle = ends[0], .flags = .{ .nonblocking = false } };
        const output: std.Io.File = .{ .handle = ends[1], .flags = .{ .nonblocking = false } };
        defer input.close(io);
        try output.writeStreamingAll(io, bytes);
        output.close(io);
        const result = wire.read(wire.Commit, std.testing.allocator, io, input, null);
        try std.testing.expectError(if (bytes.len == 4) error.BadFrame else error.EndOfStream, result);
    }
}

test "native frame roundtrip preserves nonce and commit decision" {
    const ends = try ra8.host.pipe_pair.create(.{});
    const input: std.Io.File = .{ .handle = ends[0], .flags = .{ .nonblocking = false } };
    const output: std.Io.File = .{ .handle = ends[1], .flags = .{ .nonblocking = false } };
    defer input.close(io);
    defer output.close(io);
    const nonce: ra8.host.history.name.Id = @splat('a');
    try wire.write(std.testing.allocator, io, output, wire.Commit{ .nonce = nonce, .commit = false });
    const parsed = try wire.read(wire.Commit, std.testing.allocator, io, input, null);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(&nonce, &parsed.value.nonce);
    try std.testing.expect(!parsed.value.commit);
}

test "protocol bounds are finite, nonzero and fit one pipe" {
    try (wire.Bounds{}).check();
    try std.testing.expectEqual(@as(u32, 2), wire.version);
    try std.testing.expect(wire.pipe_bytes <= 65536);
    for ([_]wire.Bounds{ .{ .ready = 0 }, .{ .commit = 0 }, .{ .drain = wire.Bounds.limit + 1 }, .{ .reap = 0 } }) |bad| try std.testing.expectError(error.BadBounds, bad.check());
}
