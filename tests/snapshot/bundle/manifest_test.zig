const std = @import("std");
const ra8 = @import("ra8");
const manifest = ra8.snapshot.bundle.manifest;

const metadata: manifest.Metadata = .{
    .board = "board\"\nname",
    .elf0 = .{ .name = "image.elf", .identity = @splat(42), .size = 123 },
};

test "bounded manifest preserves escaped metadata and snapshot format version" {
    var buffer: [8192]u8 = undefined;
    const json = try manifest.encode(&buffer, metadata, true);
    const parsed = try std.json.parseFromSlice(manifest.Manifest, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(metadata.board, parsed.value.board);
    try std.testing.expectEqualStrings("ra8-session-bundle", parsed.value.format);
    try std.testing.expectEqual(1, parsed.value.version);
    try std.testing.expectEqual(ra8.snapshot.file.version, parsed.value.snapshot_version);
    try std.testing.expectEqualStrings(metadata.elf0.name, parsed.value.elf0.name);
    try std.testing.expectEqualStrings("2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a", &parsed.value.elf0.identity);
    try std.testing.expectEqual(metadata.elf0.size, parsed.value.elf0.size);
    try std.testing.expectEqual(null, parsed.value.elf1);
    try std.testing.expect(parsed.value.recording);
}

test "metadata bounds and encoding failures are explicit" {
    var buffer: [8192]u8 = undefined;
    var value = metadata;
    for ([_][]const u8{ "", "\x00", "\xff", &(@as([257]u8, @splat('x'))) }) |bad| {
        value.board = bad;
        try std.testing.expectError(error.InvalidMetadata, manifest.encode(&buffer, value, false));
    }
    value = metadata;
    value.elf1 = .{ .name = "", .identity = @splat(0), .size = 0 };
    try std.testing.expectError(error.InvalidMetadata, manifest.encode(&buffer, value, false));
    var tiny: [8]u8 = undefined;
    try std.testing.expectError(error.WriteFailed, manifest.encode(&tiny, metadata, false));
}

test "maximum escaped labels and two images fit the bounded manifest" {
    const label: [256]u8 = @splat(1);
    var value = metadata;
    value.board = &label;
    value.elf0.name = &label;
    value.elf1 = value.elf0;
    var buffer: [8192]u8 = undefined;
    const bytes = try manifest.encode(&buffer, value, false);
    const parsed = try std.json.parseFromSlice(manifest.Manifest, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(value.elf1.?.name, parsed.value.elf1.?.name);
    try std.testing.expectEqualStrings("2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a", &parsed.value.elf1.?.identity);
    try std.testing.expect(!parsed.value.recording);
}

test "manifest admission rejects missing fields unknown versions and malformed identities" {
    var buffer: [8192]u8 = undefined;
    const bytes = try manifest.encode(&buffer, metadata, false);
    var parsed = try manifest.decode(std.testing.allocator, bytes);
    defer parsed.deinit();
    parsed.value.version = 2;
    const bad_version = try std.json.Stringify.valueAlloc(std.testing.allocator, parsed.value, .{});
    defer std.testing.allocator.free(bad_version);
    try std.testing.expectError(error.BadBundleVersion, manifest.decode(std.testing.allocator, bad_version));
    parsed.value.version = 1;
    parsed.value.elf0.identity[0] = 'G';
    const bad_identity = try std.json.Stringify.valueAlloc(std.testing.allocator, parsed.value, .{});
    defer std.testing.allocator.free(bad_identity);
    try std.testing.expectError(error.BadIdentity, manifest.decode(std.testing.allocator, bad_identity));
    try std.testing.expectError(error.MissingField, manifest.decode(std.testing.allocator, "{}"));
}
