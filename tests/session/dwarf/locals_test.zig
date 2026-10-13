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
const abbrev = [_]u8{
    0x01, 0x11, 0x01, 0x03, 0x08, 0x00, 0x00,
    0x02, 0x2e, 0x01, 0x11, 0x01, 0x12, 0x06,
    0x3b, 0x0b, 0x00, 0x00, 0x03, 0x05, 0x00,
    0x03, 0x08, 0x02, 0x18, 0x00, 0x00, 0x04,
    0x34, 0x00, 0x03, 0x08, 0x02, 0x18, 0x00,
    0x00, 0x05, 0x34, 0x00, 0x03, 0x0e, 0x02,
    0x18, 0x00, 0x00, 0x06, 0x34, 0x00, 0x03,
    0x08, 0x02, 0x0a, 0x00, 0x00, 0x07, 0x34,
    0x00, 0x00, 0x00,
};

// The DIEs: "f.c"; the function 0x1000 for 0x20 bytes on line 7; its
// parameter and locals with the four answerable locations and two the
// reader declines; the end of the function's children; a variable with
// no attributes of interest outside the function; the end of the
// unit's children.
const dies = [_]u8{
    0x01, 0x66, 0x2E, 0x63, 0x00,
    0x02, 0x00, 0x10, 0x00, 0x00,
    0x20, 0x00, 0x00, 0x00, 0x07,
    0x03, 0x6E, 0x00, 0x02, 0x91,
    0x08, 0x04, 0x63, 0x00, 0x02,
    0x7D, 0x04, 0x04, 0x72, 0x00,
    0x01, 0x55, 0x05, 0x00, 0x00,
    0x00, 0x00, 0x05, 0x03, 0x00,
    0x20, 0x00, 0x00, 0x06, 0x78,
    0x00, 0x01, 0x1E, 0x06, 0x79,
    0x00, 0x03, 0x91, 0x08, 0x0A,
    0x00, 0x07, 0x00,
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
