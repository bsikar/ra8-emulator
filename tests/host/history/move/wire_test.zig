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

test "native frame roundtrip preserves nonce, operation, proof and commit decision" {
    const ends = try ra8.host.pipe_pair.create(.{});
    const input: std.Io.File = .{ .handle = ends[0], .flags = .{ .nonblocking = false } };
    const output: std.Io.File = .{ .handle = ends[1], .flags = .{ .nonblocking = false } };
    defer input.close(io);
    defer output.close(io);
    const nonce: ra8.host.history.name.Id = @splat('a');
    const proof: wire.Proof = .{ .anchor = wire.digest("anchor"), .note = wire.digest("note") };
    try wire.write(std.testing.allocator, io, output, wire.Commit{ .version = wire.version, .nonce = nonce, .operation = @splat('b'), .proof = proof, .commit = false });
    const parsed = try wire.read(wire.Commit, std.testing.allocator, io, input, null);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(&nonce, &parsed.value.nonce);
    try std.testing.expectEqualStrings(&@as(ra8.host.history.name.Id, @splat('b')), &parsed.value.operation);
    try std.testing.expect(std.meta.eql(proof, parsed.value.proof));
    try std.testing.expect(!parsed.value.commit);
}

test "protocol bounds are finite, nonzero and fit one pipe" {
    try (wire.Bounds{}).check();
    try std.testing.expectEqual(@as(u32, 3), wire.version);
    try std.testing.expect(wire.pipe_bytes <= 65536);
    for ([_]wire.Bounds{ .{ .ready = 0 }, .{ .commit = 0 }, .{ .drain = wire.Bounds.limit + 1 }, .{ .reap = 0 }, .{ .settle = 0 } }) |bad| try std.testing.expectError(error.BadBounds, bad.check());
}

test "the default phases are the experimental targets and fill one admission with no grace" {
    const bounds: wire.Bounds = .{};
    try std.testing.expectEqual([5]u32{ 10_000, 5_000, 5_000, 2_000, 2_000 }, [5]u32{ bounds.ready, bounds.commit, bounds.drain, bounds.reap, bounds.settle });
    try std.testing.expectEqual(@as(u64, 24_000), bounds.total());
    const wide: wire.Bounds = .{ .ready = 20_000, .commit = 20_000, .drain = 20_000 };
    try std.testing.expect(wide.total() > wire.Bounds.limit);
    try std.testing.expectError(error.BadBounds, wide.check());
}

test "a frame missing a field, carrying an unknown one or a short digest is refused" {
    const ends = try ra8.host.pipe_pair.create(.{});
    const input: std.Io.File = .{ .handle = ends[0], .flags = .{ .nonblocking = false } };
    const output: std.Io.File = .{ .handle = ends[1], .flags = .{ .nonblocking = false } };
    defer input.close(io);
    defer output.close(io);
    const hex: [64]u8 = @splat('0');
    const id: [32]u8 = @splat('a');
    const head = "{\"version\":3,\"nonce\":\"" ++ id ++ "\",\"operation\":\"" ++ id ++ "\"";
    const frames = [_][]const u8{
        head ++ ",\"commit\":true}",
        head ++ ",\"proof\":{\"anchor\":\"" ++ hex ++ "\",\"note\":\"" ++ hex ++ "\"},\"commit\":true,\"pid\":1}",
        head ++ ",\"proof\":{\"anchor\":\"00\",\"note\":\"" ++ hex ++ "\"},\"commit\":true}",
    };
    for (frames) |text| {
        var prefix: [4]u8 = undefined;
        std.mem.writeInt(u32, &prefix, @intCast(text.len), .little);
        try output.writeStreamingAll(io, &prefix);
        try output.writeStreamingAll(io, text);
        if (wire.read(wire.Commit, std.testing.allocator, io, input, null)) |parsed| {
            parsed.deinit();
            return error.TestUnexpectedResult;
        } else |_| {}
    }
    // The same head with a whole proof is a valid frame.
    const whole = head ++ ",\"proof\":{\"anchor\":\"" ++ hex ++ "\",\"note\":\"" ++ hex ++ "\"},\"commit\":true}";
    var prefix: [4]u8 = undefined;
    std.mem.writeInt(u32, &prefix, whole.len, .little);
    try output.writeStreamingAll(io, &prefix);
    try output.writeStreamingAll(io, whole);
    const parsed = try wire.read(wire.Commit, std.testing.allocator, io, input, null);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.commit);
}

test "a digest is the lowercase hex SHA-256 of the exact bytes" {
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", &wire.digest("abc"));
    try std.testing.expect(!std.mem.eql(u8, &wire.digest("anchor"), &wire.digest("anchor\nCOMMIT\n")));
}
