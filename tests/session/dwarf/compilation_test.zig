const std = @import("std");
const compilation = @import("ra8").session.dwarf.compilation;
const allocator = std.testing.allocator;
const line = @import("ra8").session.dwarf.line;
// stmt_list data4, comp_dir string; reversed comp_dir strp and stmt_list
// sec_offset; indexed string with the base deliberately following the index.
const abbrev = [_]u8{
    1, 0x11, 0, 0x10, 0x06, 0x1b, 0x08, 0,    0,
    2, 0x11, 0, 0x1b, 0x0e, 0x10, 0x17, 0,    0,
    3, 0x11, 0, 0x1b, 0x25, 0x72, 0x17, 0x10, 0x17,
    0, 0,    4, 0x11, 0,    0x1b, 0x1f, 0x10, 0x17,
    0, 0,    0,
};

fn unit(out: *std.Io.Writer, version: u16, dies: []const u8) !void {
    try out.writeInt(u32, @as(u32, @intCast(dies.len)) + if (version >= 5) @as(u32, 8) else 7, .little);
    try out.writeInt(u16, version, .little);
    if (version >= 5) try out.writeAll(&.{ 1, 4 });
    try out.writeInt(u32, 0, .little);
    if (version < 5) try out.writeByte(4);
    try out.writeAll(dies);
}

test "DWARF 2 through 5 CU directories are associated by statement-list offset rather than unit order" {
    for (2..6) |version| {
        var bytes: std.Io.Writer.Allocating = .init(allocator);
        defer bytes.deinit();
        try unit(&bytes.writer, @intCast(version), "\x01\x40\x00\x00\x00/other\x00");
        try unit(&bytes.writer, @intCast(version), "\x01\x00\x00\x00\x00C:\\project with spaces\x00");
        const sections: compilation.Sections = .{ .info = bytes.written(), .abbrev = &abbrev };
        try std.testing.expectEqualStrings("C:\\project with spaces", try compilation.directory(sections, 0));
        try std.testing.expectEqualStrings("/other", try compilation.directory(sections, 0x40));
        try std.testing.expectEqualStrings("", try compilation.directory(sections, 0x80));
    }
}

test "CU directories resolve strp line_strp and indexed strings with a later string base" {
    var bytes: std.Io.Writer.Allocating = .init(allocator);
    defer bytes.deinit();
    try unit(&bytes.writer, 4, &.{ 2, 6, 0, 0, 0, 0, 0, 0, 0 });
    try unit(&bytes.writer, 5, &.{ 3, 1, 4, 0, 0, 0, 0x40, 0, 0, 0 });
    try unit(&bytes.writer, 5, &.{ 4, 0, 0, 0, 0, 0x80, 0, 0, 0 });
    const sections: compilation.Sections = .{ .info = bytes.written(), .abbrev = &abbrev, .strings = "other\x00/project\x00", .line_strings = "/line-strings\x00", .string_offsets = &.{ 99, 99, 99, 99, 0, 0, 0, 0, 6, 0, 0, 0 } };
    try std.testing.expectEqualStrings("/project", try compilation.directory(sections, 0));
    try std.testing.expectEqualStrings("/project", try compilation.directory(sections, 0x40));
    try std.testing.expectEqualStrings("/line-strings", try compilation.directory(sections, 0x80));
}

test "truncated or ambiguous CU metadata is refused rather than borrowing a different directory" {
    var bytes: std.Io.Writer.Allocating = .init(allocator);
    defer bytes.deinit();
    try unit(&bytes.writer, 4, "\x01\x00\x00\x00\x00/first\x00");
    const complete = bytes.written().len;
    for (1..complete) |end| try std.testing.expectError(error.Truncated, compilation.directory(.{ .info = bytes.written()[0..end], .abbrev = &abbrev }, 0));
    try unit(&bytes.writer, 4, "\x01\x00\x00\x00\x00/second\x00");
    try std.testing.expectError(error.Unsupported, compilation.directory(.{ .info = bytes.written(), .abbrev = &abbrev }, 0));
}

fn appendRoot(out: *std.Io.Writer, statement_list: u32, directory: []const u8) !void {
    var die: std.Io.Writer.Allocating = .init(allocator);
    defer die.deinit();
    try die.writer.writeByte(1);
    try die.writer.writeInt(u32, statement_list, .little);
    try die.writer.writeAll(directory);
    try die.writer.writeByte(0);
    try unit(out, 4, die.written());
}

test "source address and stack lookup qualify identical basenames with their own CU directory" {
    var rows: std.ArrayList(u8) = .empty;
    defer rows.deinit(allocator);
    const line_unit = @import("../dwarf_units.zig").unit;
    const tables = "\x00main.c\x00\x00\x00\x00\x00";
    const program = [_]u8{ 0, 5, 2, 0, 0x10, 0, 0, 1, 2, 1, 0, 1, 1 };
    try line_unit(&rows, 4, 2, tables, &program);
    const second_offset: u32 = @intCast(rows.items.len);
    var second = program;
    second[4] = 0x20;
    try line_unit(&rows, 4, 2, tables, &second);
    var info_bytes: std.Io.Writer.Allocating = .init(allocator);
    defer info_bytes.deinit();
    try appendRoot(&info_bytes.writer, second_offset, "/two");
    try appendRoot(&info_bytes.writer, 0, "/one");
    const sections: line.Sections = .{ .line = rows.items, .units = .{ .info = info_bytes.written(), .abbrev = &abbrev } };
    try std.testing.expectEqual(@as(?u32, 0x1000), try line.find.addressOf(sections, "/one/main.c", 1));
    try std.testing.expectEqual(@as(?u32, 0x2000), try line.find.addressOf(sections, "/two/main.c", 1));
    try std.testing.expectEqual(@as(?u32, null), try line.find.addressOf(sections, "/other/main.c", 1));
    const first_place = (try line.lookup(sections, 0x1000)).?;
    const second_place = (try line.lookup(sections, 0x2000)).?;
    try std.testing.expectEqualStrings("/one", first_place.file.compilation_directory);
    try std.testing.expectEqualStrings("/two", second_place.file.compilation_directory);
    var damaged = sections;
    damaged.units.info = damaged.units.info[0 .. damaged.units.info.len - 1];
    try std.testing.expectEqual(@as(?u32, null), try line.find.addressOf(damaged, "/one/main.c", 1));
    try std.testing.expectEqual(@as(?u32, 0x1000), try line.find.addressOf(damaged, "main.c", 1));
}

test "all DWARF indexed string widths resolve the CU base and refuse out-of-range offsets" {
    for ([_]u8{ 0x1a, 0x25, 0x26, 0x27, 0x28 }, [_]usize{ 1, 1, 2, 3, 4 }) |form, width| {
        const spec = [_]u8{ 1, 0x11, 0, 0x1b, form, 0x72, 0x17, 0x10, 0x17, 0, 0, 0 };
        var die: std.Io.Writer.Allocating = .init(allocator);
        defer die.deinit();
        try die.writer.writeAll(&.{ 1, 1 });
        for (1..width) |_| try die.writer.writeByte(0);
        try die.writer.writeInt(u32, 0, .little);
        try die.writer.writeInt(u32, 0, .little);
        var bytes: std.Io.Writer.Allocating = .init(allocator);
        defer bytes.deinit();
        try unit(&bytes.writer, 5, die.written());
        const sections: compilation.Sections = .{ .info = bytes.written(), .abbrev = &spec, .strings = "none\x00/indexed\x00", .string_offsets = &.{ 0, 0, 0, 0, 5, 0, 0, 0 } };
        try std.testing.expectEqualStrings("/indexed", try compilation.directory(sections, 0));
        var broken = sections;
        broken.string_offsets = &.{0};
        try std.testing.expectError(error.Truncated, compilation.directory(broken, 0));
    }
}

test "a directory without a statement association stays unknown and duplicate relevant attributes are refused" {
    const no_statement = [_]u8{ 1, 0x11, 0, 0x1b, 0x08, 0, 0, 0 };
    var bytes: std.Io.Writer.Allocating = .init(allocator);
    defer bytes.deinit();
    try unit(&bytes.writer, 4, "\x01/not-associated\x00");
    try std.testing.expectEqualStrings("", try compilation.directory(.{ .info = bytes.written(), .abbrev = &no_statement }, 0));
    const duplicate = [_]u8{ 1, 0x11, 0, 0x10, 0x06, 0x10, 0x06, 0, 0, 0 };
    var repeated: std.Io.Writer.Allocating = .init(allocator);
    defer repeated.deinit();
    try unit(&repeated.writer, 4, &.{ 1, 0, 0, 0, 0, 0, 0, 0, 0 });
    try std.testing.expectError(error.Unsupported, compilation.directory(.{ .info = repeated.written(), .abbrev = &duplicate }, 0));
}
