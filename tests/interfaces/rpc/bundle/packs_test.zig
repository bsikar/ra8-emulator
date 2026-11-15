const std = @import("std");
const ra8 = @import("ra8");

const fixture = @import("fixture.zig");
const gpa = std.testing.allocator;

fn payload(bytes: []u8, suffix: []const u8) ![]u8 {
    var input = std.Io.Reader.fixed(bytes);
    var names: [256]u8 = undefined;
    var links: [1]u8 = undefined;
    var tar = std.tar.Iterator.init(&input, .{ .file_name_buffer = &names, .link_name_buffer = &links });
    while (try tar.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, suffix)) return input.buffered()[0..@intCast(entry.size)];
    }
    return error.MissingFixturePack;
}

fn reject(bytes: []u8, expected: anyerror) !void {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(path);
    var input = std.Io.Reader.fixed(bytes);
    try std.testing.expectError(expected, ra8.rpc.bundle_import.open(gpa, std.testing.io, &input, .{ .history_root = path }));
    var base = try ra8.host.history.base.Base.existingConfigured(gpa, std.testing.io, path, .cache, .{ .recover = false });
    defer base.close();
    var catalog = try ra8.host.history.catalog.Iterator.init(&base);
    try std.testing.expectEqual(null, try catalog.next());
}

test "corrupt imported pack indexes fail instead of being silently rebuilt" {
    var archive = try fixture.recording(false);
    defer archive.deinit();
    const bytes = try payload(archive.bytes.written(), ".idx");
    bytes[bytes.len - 1] ^= 1;
    try reject(archive.bytes.written(), error.BadMagic);
}

test "declared pack expansion is bounded before allocating decompression output" {
    var archive = try fixture.recording(false);
    defer archive.deinit();
    const bytes = try payload(archive.bytes.written(), ".pack");
    const at = ra8.session.history_pack.header_len + 16;
    std.mem.writeInt(u32, bytes[at..][0..4], std.math.maxInt(u32), .little);
    try reject(archive.bytes.written(), error.TooLarge);
}
