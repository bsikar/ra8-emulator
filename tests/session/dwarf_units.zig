//! Hand-built .debug_line units for the DWARF tests, so each test states
//! only its tables and program.
const std = @import("std");

/// The standard opcode operand counts every unit here declares.
const lengths = [_]u8{ 0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1 };

/// A unit: its length, version, any v5 address fields, the header length,
/// the fixed fields, `tables`, then `program`.
pub fn unit(list: *std.ArrayList(u8), version: u16, min_length: u8, tables: []const u8, program: []const u8) !void {
    const gpa = std.testing.allocator;
    var head: std.ArrayList(u8) = .empty;
    defer head.deinit(gpa);
    try head.appendSlice(gpa, &.{ min_length, 1, 1, 0xfb, 14, 13 });
    try head.appendSlice(gpa, &lengths);
    try head.appendSlice(gpa, tables);
    const prefix: usize = if (version >= 5) 2 else 0;
    const length: u32 = @intCast(2 + prefix + 4 + head.items.len + program.len);
    try list.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, length)));
    try list.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, version)));
    if (version >= 5) try list.appendSlice(gpa, &.{ 4, 0 });
    try list.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, @as(u32, @intCast(head.items.len)))));
    try list.appendSlice(gpa, head.items);
    try list.appendSlice(gpa, program);
}
