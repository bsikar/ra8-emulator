//! Associate each line table with its compilation unit's source directory.
const std = @import("std");
const reading = @import("cursor.zig");
const info = @import("info.zig");
const Cursor = reading.Cursor;
pub const Sections = struct {
    info: []const u8 = &.{},
    abbrev: []const u8 = &.{},
    strings: []const u8 = &.{},
    line_strings: []const u8 = &.{},
    string_offsets: []const u8 = &.{},
};
const Value = union(enum) { none, number: u64, text: []const u8, string_index: u64 };
const Root = struct { statement_list: ?u64 = null, directory: Value = .none, string_base: ?u64 = null };

/// No working-directory assumption: missing or unsupported metadata stays unknown.
pub fn directory(sections: Sections, line_offset: usize) reading.Error![]const u8 {
    var offset: usize = 0;
    var found: ?[]const u8 = null;
    while (offset < sections.info.len) {
        var cursor: Cursor = .{ .bytes = sections.info, .at = offset };
        const length = try cursor.int(u32);
        if (length >= 0xffff_fff0) return error.Unsupported;
        if (length > sections.info.len - cursor.at) return error.Truncated;
        const end = cursor.at + length;
        cursor.bytes = sections.info[0..end];
        offset = end;
        const abbrev = try info.header(&cursor, sections.abbrev) orelse continue;
        const root = try readRoot(&cursor, abbrev, sections);
        if (root.statement_list == null or root.statement_list.? != line_offset) continue;
        const text = try rootDirectory(root, sections);
        if (found) |previous| {
            if (!std.mem.eql(u8, previous, text)) return error.Unsupported;
        } else found = text;
    }
    return found orelse "";
}

fn readRoot(cursor: *Cursor, abbrev: []const u8, sections: Sections) reading.Error!Root {
    const code = try cursor.uleb();
    if (code == 0) return .{};
    var spec = try info.find(abbrev, code);
    if (spec.tag != 0x11 and spec.tag != 0x3c) return .{}; // compile/partial unit.
    var root: Root = .{};
    var seen: u8 = 0;
    while (true) {
        const name = try spec.cursor.uleb();
        const form = try spec.cursor.uleb();
        if (name == 0 and form == 0) break;
        const implicit: i64 = if (form == 0x21) try spec.cursor.sleb() else 0;
        const value = try readValue(cursor, form, implicit, sections);
        const bit: u8 = switch (name) {
            0x10 => 1,
            0x1b => 2,
            0x72 => 4,
            else => 0,
        };
        if (seen & bit != 0) return error.Unsupported;
        seen |= bit;
        switch (name) {
            0x10 => if (value == .number) {
                root.statement_list = value.number;
            },
            0x1b => root.directory = value,
            0x72 => if (value == .number) {
                root.string_base = value.number;
            },
            else => {},
        }
    }
    return root;
}

fn rootDirectory(root: Root, sections: Sections) reading.Error![]const u8 {
    return switch (root.directory) {
        .text => |text| text,
        .string_index => |index| blk: {
            const base = root.string_base orelse return error.Unsupported;
            const relative = std.math.mul(u64, index, 4) catch return error.Truncated;
            const offset = std.math.add(u64, base, relative) catch return error.Truncated;
            var cursor: Cursor = .{ .bytes = sections.string_offsets, .at = std.math.cast(usize, offset) orelse return error.Truncated };
            if (cursor.at > cursor.bytes.len) return error.Truncated;
            break :blk try reading.stringAt(sections.strings, try cursor.int(u32));
        },
        else => "",
    };
}

fn readValue(cursor: *Cursor, original: u64, implicit: i64, sections: Sections) reading.Error!Value {
    var form = original;
    for (0..16) |_| {
        if (form != 0x16) break;
        form = try cursor.uleb();
    }
    if (form == 0x16) return error.Unsupported;
    if (form == 0x21 and original != 0x21) return error.Unsupported;
    return switch (form) {
        0x08 => .{ .text = try cursor.string() },
        0x0e => .{ .text = try reading.stringAt(sections.strings, try cursor.int(u32)) },
        0x1f => .{ .text = try reading.stringAt(sections.line_strings, try cursor.int(u32)) },
        0x1a => .{ .string_index = try cursor.uleb() },
        0x25 => .{ .string_index = try cursor.byte() },
        0x26 => .{ .string_index = try cursor.int(u16) },
        0x27 => .{ .string_index = std.mem.readInt(u24, (try cursor.take(3))[0..3], .little) },
        0x28 => .{ .string_index = try cursor.int(u32) },
        0x06, 0x17 => .{ .number = try cursor.int(u32) },
        0x07 => .{ .number = try cursor.int(u64) },
        0x0f => .{ .number = try cursor.uleb() },
        0x21 => .{ .number = @bitCast(implicit) },
        else => blk: {
            try info.skip(cursor, form);
            break :blk .none;
        },
    };
}
