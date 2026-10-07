//! RA8EMU-659: the snapshot file's header and sections.
const std = @import("std");
const ra8 = @import("ra8");
const file = ra8.snapshot.file;

fn build(list: *std.ArrayList(u8)) !void {
    const writer = list.writer();
    try file.writeHeader(writer);
    try file.writeSectionHeader(writer, @fromBackingInt(@intCast(77)), 3);
    try writer.writeAll("abc");
    try file.writeSectionHeader(writer, .memory, 2);
    try writer.writeAll("xy");
}

test "sections come back in order, and an unknown kind is just skipped" {
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    try build(&list);
    var reader = try file.Reader.open(list.items);
    const first = (try reader.next()).?;
    try std.testing.expectEqual(@as(u32, 77), @backingInt(first.kind));
    try std.testing.expectEqualStrings("abc", first.payload);
    try std.testing.expectEqualStrings("xy", (try reader.next()).?.payload);
    try std.testing.expect(try reader.next() == null);
    const found = (try file.Reader.find(list.items, .memory)).?;
    try std.testing.expectEqualStrings("xy", found.payload);
}

test "a wrong magic or an unknown version is refused" {
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    try build(&list);
    list.items[0] = 'X';
    try std.testing.expectError(error.BadMagic, file.Reader.open(list.items));
    list.items[0] = file.magic[0];
    std.mem.writeInt(u32, list.items[file.magic.len..][0..4], file.version + 1, .little);
    try std.testing.expectError(error.BadVersion, file.Reader.open(list.items));
}

test "a cut-off file is truncated, not misread" {
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    try build(&list);
    try std.testing.expectError(error.Truncated, file.Reader.open(list.items[0..5]));
    var reader = try file.Reader.open(list.items[0 .. list.items.len - 1]);
    _ = try reader.next();
    try std.testing.expectError(error.Truncated, reader.next());
}
