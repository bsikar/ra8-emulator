//! `info line`: gdb's wording for an address with a line, with a directory
//! or an absolute name, and for one without.
const std = @import("std");
const ra8 = @import("ra8");

const commands = ra8.core.commands;
const session_source = ra8.core.session_source;
const unit = @import("dwarf_units.zig").unit;

// Directories "src"; files "main.c" in directory 1, "/abs/boot.s" in 0.
const tables = "src\x00\x00main.c\x00\x01\x00\x00/abs/boot.s\x00\x00\x00\x00\x00";
// set_address 0x1000; copy (line 1); advance_pc 2 ops (4 bytes); set_file 2;
// advance_line +6; copy (0x1004, line 7); advance_pc 1 op; end_sequence.
const program = [_]u8{ 0x00, 0x05, 0x02, 0x00, 0x10, 0x00, 0x00, 0x01, 0x02, 0x02, 0x04, 0x02, 0x03, 0x06, 0x01, 0x02, 0x01, 0x00, 0x01, 0x01 };

fn said(sections: ra8.core.dwarf_line.Sections, address: u32, expected: []const u8) !void {
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try session_source.line(out.writer(), sections, address);
    try std.testing.expectEqualStrings(expected, out.items);
}

test "info line names the file under its directory and the row's addresses" {
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    try unit(&list, 4, 2, tables, &program);
    const sections = ra8.core.dwarf_line.Sections{ .line = list.items };
    try said(sections, 0x1002, "Line 1 of \"src/main.c\" starts at address 0x00001000 and ends at 0x00001004.\n");
    try said(sections, 0x1005, "Line 7 of \"/abs/boot.s\" starts at address 0x00001004 and ends at 0x00001006.\n");
    try said(sections, 0x1006, "No line number information available for address 0x00001006\n");
}

test "info line ends where the line changes, past rows on the same line" {
    // set_address 0x1000; copy (line 1); advance_pc 1 op; copy (0x1002, line
    // 1 again); advance_pc 1 op; advance_line +1; copy (0x1004, line 2);
    // advance_pc 1 op; end_sequence at 0x1006.
    const repeated = [_]u8{ 0x00, 0x05, 0x02, 0x00, 0x10, 0x00, 0x00, 0x01, 0x02, 0x01, 0x01, 0x02, 0x01, 0x03, 0x01, 0x01, 0x02, 0x01, 0x00, 0x01, 0x01 };
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    try unit(&list, 4, 2, tables, &repeated);
    const sections = ra8.core.dwarf_line.Sections{ .line = list.items };
    try said(sections, 0x1000, "Line 1 of \"src/main.c\" starts at address 0x00001000 and ends at 0x00001004.\n");
    try said(sections, 0x1003, "Line 1 of \"src/main.c\" starts at address 0x00001002 and ends at 0x00001004.\n");
}

test "an image with no line table, or a damaged one, has no line to give" {
    try said(session_source.of(null), 0x22000000, "No line number information available for address 0x22000000\n");
    const damaged = [_]u8{ 0x40, 0, 0, 0, 4, 0 };
    try said(.{ .line = &damaged }, 0x10, "No line number information available for address 0x00000010\n");
}

test "info line takes one place" {
    const parsed = (try commands.parse("info line target+4")).?;
    try std.testing.expectEqualStrings("target+4", parsed.line);
    try std.testing.expectError(error.MissingArgument, commands.parse("info line"));
    try std.testing.expectError(error.ExtraArgument, commands.parse("info line a b"));
}
