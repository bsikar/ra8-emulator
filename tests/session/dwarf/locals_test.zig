//! Locals of a function from hand-built .debug_info units: names in
//! string and strp forms, locations in the shapes a stopped core can
//! answer, and everything else left with no location.
const std = @import("std");
const ra8 = @import("ra8");

const locals = ra8.session.dwarf.locals;

// 1: compile_unit with children, name string. 2: subprogram with
// children, low_pc addr, high_pc data4, decl_line data1. 3:
// formal_parameter, name string, location exprloc. 4: variable, name
// string, location exprloc. 5: variable, name strp, location exprloc.
// 6: variable, name string, location block1. 7: variable, no attributes
// of interest.
// 8: base_type, name string, byte_size data1.
const abbrev = [_]u8{
    0x01, 0x11, 0x01, 0x03, 0x08, 0x00, 0x00,
    0x02, 0x2e, 0x01, 0x11, 0x01, 0x12, 0x06,
    0x3b, 0x0b, 0x00, 0x00, 0x03, 0x05, 0x00,
    0x03, 0x08, 0x02, 0x18, 0x00, 0x00, 0x04,
    0x34, 0x00, 0x03, 0x08, 0x02, 0x18, 0x00,
    0x00, 0x05, 0x34, 0x00, 0x03, 0x0e, 0x02,
    0x18, 0x49, 0x13, 0x00, 0x00, 0x06, 0x34,
    0x00, 0x03, 0x08, 0x02, 0x0a, 0x00, 0x00,
    0x07, 0x34, 0x00, 0x00, 0x00, 0x08, 0x24,
    0x00, 0x03, 0x08, 0x0b, 0x0b, 0x00, 0x00,
};

// The DIEs: "f.c"; the function 0x1000 for 0x20 bytes on line 7; its
// parameter and locals with the four answerable locations and two the
// reader declines; the end of the function's children; a variable with
// no attributes of interest outside the function; the end of the
// unit's children.
// The base type sits as the unit's first child; slot's DW_AT_type
// ref4 names it at unit-relative offset 16 (the header's 11 bytes
// count toward the offset).
const dies = [_]u8{
    0x01, 0x66, 0x2E, 0x63, 0x00,
    0x08, 0x63, 0x68, 0x61, 0x72,
    0x00, 0x01, 0x02, 0x00, 0x10,
    0x00, 0x00, 0x20, 0x00, 0x00,
    0x00, 0x07, 0x03, 0x6E, 0x00,
    0x02, 0x91, 0x08, 0x04, 0x63,
    0x00, 0x02, 0x7D, 0x04, 0x04,
    0x72, 0x00, 0x01, 0x55, 0x05,
    0x00, 0x00, 0x00, 0x00, 0x05,
    0x03, 0x00, 0x20, 0x00, 0x00,
    0x10, 0x00, 0x00, 0x00, 0x06,
    0x78, 0x00, 0x01, 0x1E, 0x06,
    0x79, 0x00, 0x03, 0x91, 0x08,
    0x0A, 0x00, 0x07, 0x00, 0x00,
};

const str = "slot\x00";

fn expectLocal(found: []locals.Local, at: usize, name: []const u8, where: ?locals.Where) !void {
    try std.testing.expectEqualStrings(name, found[at].name);
    try std.testing.expectEqualDeep(where, found[at].where);
}

test "a function's locals come out with the four answerable locations" {
    var list: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer list.deinit();
    try unit(&list.writer, 4);
    const sections = locals.Sections{ .info = list.written(), .abbrev = &abbrev, .str = str };
    var into: [8]locals.Local = undefined;
    try std.testing.expectEqual(@as(usize, 6), try locals.inFunction(sections, 0x1000, &into));
    try expectLocal(into[0..], 0, "n", .{ .frame = 8 });
    try expectLocal(into[0..], 1, "c", .{ .register = .{ .reg = 13, .offset = 4 } });
    try expectLocal(into[0..], 2, "r", .{ .in_register = 5 });
    try expectLocal(into[0..], 3, "slot", .{ .address = 0x2000 });
    try expectLocal(into[0..], 4, "x", null);
    try expectLocal(into[0..], 5, "y", null);
}

test "a smaller buffer takes the first locals and says how many fit" {
    var list: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer list.deinit();
    try unit(&list.writer, 4);
    const sections = locals.Sections{ .info = list.written(), .abbrev = &abbrev, .str = str };
    var into: [2]locals.Local = undefined;
    try std.testing.expectEqual(@as(usize, 2), try locals.inFunction(sections, 0x1000, &into));
    try expectLocal(into[0..], 0, "n", .{ .frame = 8 });
    try expectLocal(into[0..], 1, "c", .{ .register = .{ .reg = 13, .offset = 4 } });
}

test "another function's address answers nothing here" {
    var list: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer list.deinit();
    try unit(&list.writer, 4);
    const sections = locals.Sections{ .info = list.written(), .abbrev = &abbrev, .str = str };
    var into: [8]locals.Local = undefined;
    try std.testing.expectEqual(@as(usize, 0), try locals.inFunction(sections, 0x0FFF, &into));
    try std.testing.expectEqual(@as(usize, 0), try locals.inFunction(sections, 0x1020, &into));
}

test "a DWARF 5 unit reads the same" {
    var list: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer list.deinit();
    try unit(&list.writer, 5);
    const sections = locals.Sections{ .info = list.written(), .abbrev = &abbrev, .str = str };
    var into: [8]locals.Local = undefined;
    try std.testing.expectEqual(@as(usize, 6), try locals.inFunction(sections, 0x1000, &into));
    try expectLocal(into[0..], 0, "n", .{ .frame = 8 });
}

test "a local carries its type's name and byte size" {
    var list: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer list.deinit();
    try unit(&list.writer, 4);
    const sections = locals.Sections{ .info = list.written(), .abbrev = &abbrev, .str = str };
    var into: [8]locals.Local = undefined;
    try std.testing.expectEqual(@as(usize, 6), try locals.inFunction(sections, 0x1000, &into));
    try std.testing.expectEqualStrings("char", into[3].type_name);
    try std.testing.expectEqual(@as(u32, 1), into[3].size);
    try std.testing.expectEqual(@as(u32, 0), into[0].size);
}

test "a childless function cannot collect sibling locals across exact ranges" {
    const scope_abbrev = abbrev ++ [_]u8{
        // Childless subprogram with [low_pc, high_pc).
        0x09, 0x2e, 0x00, 0x11, 0x01, 0x12, 0x06, 0x00, 0x00,
        // Lexical block with children and no attributes.
        0x0a, 0x0b, 0x01, 0x00, 0x00,
    };
    const scope_dies = [_]u8{
        0x01, 'f',  0x00,
        // Reset_Handler [0x3000, 0x3010), no children.
        0x09, 0x00, 0x30,
        0x00, 0x00, 0x10,
        0x00, 0x00, 0x00,
        // first [0x3010, 0x3020), alpha inside a lexical block.
        0x02, 0x10, 0x30,
        0x00, 0x00, 0x10,
        0x00, 0x00, 0x00,
        0x01, 0x0a, 0x04,
        'a',  'l',  'p',
        'h',  'a',  0x00,
        0x01, 0x50, 0x00,
        0x00,
        // An empty child-bearing function [0x3020, 0x3030).
        0x02, 0x20,
        0x30, 0x00, 0x00,
        0x10, 0x00, 0x00,
        0x00, 0x01, 0x00,
        // second [0x3030, 0x3040), beta directly under it.
        0x02, 0x30, 0x30,
        0x00, 0x00, 0x10,
        0x00, 0x00, 0x00,
        0x01, 0x04, 'b',
        'e',  't',  'a',
        0x00, 0x01, 0x51,
        0x00, 0x00,
    };
    var list: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer list.deinit();
    try list.writer.writeInt(u32, 7 + scope_dies.len, .little);
    try list.writer.writeInt(u16, 4, .little);
    try list.writer.writeInt(u32, 0, .little);
    try list.writer.writeByte(4);
    try list.writer.writeAll(&scope_dies);
    const sections = locals.Sections{ .info = list.written(), .abbrev = &scope_abbrev };
    var into: [4]locals.Local = undefined;
    for ([_]u32{ 0x2fff, 0x3000, 0x300f, 0x3020, 0x302f, 0x3040 }) |pc| {
        try std.testing.expectEqual(@as(usize, 0), try locals.inFunction(sections, pc, &into));
    }
    for ([_]u32{ 0x3010, 0x301f }) |pc| {
        try std.testing.expectEqual(@as(usize, 1), try locals.inFunction(sections, pc, &into));
        try expectLocal(&into, 0, "alpha", .{ .in_register = 0 });
    }
    for ([_]u32{ 0x3030, 0x303f }) |pc| {
        try std.testing.expectEqual(@as(usize, 1), try locals.inFunction(sections, pc, &into));
        try expectLocal(&into, 0, "beta", .{ .in_register = 1 });
    }
}

/// A unit: its length, version, any v5 fields, the header length, the
/// fixed fields, then the DIEs.
fn unit(list: *std.Io.Writer, version: u16) !void {
    const head: u32 = if (version >= 5) 8 else 7;
    try list.writeInt(u32, head + @as(u32, dies.len), .little);
    try list.writeInt(u16, version, .little);
    if (version >= 5) try list.writeAll(&.{ 0x01, 0x04 });
    try list.writeInt(u32, 0, .little);
    if (version < 5) try list.writeByte(0x04);
    try list.writeAll(&dies);
}
