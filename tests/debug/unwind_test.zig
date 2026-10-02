//! Walking a call chain with .debug_frame: a leaf that keeps its return
//! address in lr, a caller that pushed lr and r4, and an outer frame.
const std = @import("std");
const ra8 = @import("ra8");

const unwind = ra8.core.unwind;

/// Two stacked words at 0x100: the caller's saved r4, then its saved lr.
const Memory = struct {
    words: [2]u32,

    pub fn readWord(self: Memory, address: u32) !u32 {
        if (address < 0x100 or address >= 0x108 or address % 4 != 0) return error.Unreadable;
        return self.words[(address - 0x100) / 4];
    }
};

fn entry(list: *std.ArrayList(u8), head: []const u8, program: []const u8) !void {
    try list.writer().writeInt(u32, @intCast(head.len + program.len), .little);
    try list.appendSlice(head);
    try list.appendSlice(program);
}

fn fde(list: *std.ArrayList(u8), start: u32, range: u32, program: []const u8) !void {
    var head: [12]u8 = undefined;
    std.mem.writeInt(u32, head[0..4], 0, .little);
    std.mem.writeInt(u32, head[4..8], start, .little);
    std.mem.writeInt(u32, head[8..12], range, .little);
    try entry(list, &head, program);
}

/// Leaf 0x1000..0x1010; caller 0x1010..0x1020 that pushes {r4, lr} at
/// 0x1012; outer 0x1030..0x1040 that never moves sp.
fn build(list: *std.ArrayList(u8)) !void {
    const cie_head = [_]u8{ 0xff, 0xff, 0xff, 0xff, 4, 0, 4, 0, 0x02, 0x7c, 0x0e };
    try entry(list, &cie_head, &.{ 0x0c, 0x0d, 0x00 });
    try fde(list, 0x1000, 0x10, &.{});
    try fde(list, 0x1010, 0x10, &.{ 0x41, 0x0e, 0x08, 0x8e, 0x01, 0x84, 0x02 });
    try fde(list, 0x1030, 0x10, &.{});
}

fn stopped(pc: u32) unwind.Registers {
    var registers = std.mem.zeroes(unwind.Registers);
    registers[4] = 0x99;
    registers[13] = 0x100;
    registers[14] = 0x1021;
    registers[15] = pc;
    return registers;
}

test "the caller's sp is the CFA and its saved registers come off the stack" {
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    try build(&list);
    const memory = Memory{ .words = .{ 0x44, 0x1035 } };
    var inner = stopped(0x1004);
    inner[15] = 0x1020;
    const outer = (try unwind.caller(list.items, inner, false, memory)).?;
    try std.testing.expectEqual(@as(u32, 0x108), outer[13]);
    try std.testing.expectEqual(@as(u32, 0x44), outer[4]);
    try std.testing.expectEqual(@as(u32, 0x1035), outer[15]);
}

test "the walk looks a return address up one byte back and stops when nothing moves" {
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    try build(&list);
    var pcs: [unwind.limits.frames]u32 = undefined;
    const count = unwind.walk(list.items, stopped(0x1004), Memory{ .words = .{ 0x44, 0x1035 } }, &pcs);
    try std.testing.expectEqualSlices(u32, &.{ 0x1004, 0x1020, 0x1034 }, pcs[0..count]);
}

test "an EXC_RETURN ends the walk, and so does a pc with no FDE" {
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    try build(&list);
    var pcs: [unwind.limits.frames]u32 = undefined;
    const handler = Memory{ .words = .{ 0x44, 0xFFFF_FFF9 } };
    try std.testing.expectEqual(@as(usize, 2), unwind.walk(list.items, stopped(0x1004), handler, &pcs));
    try std.testing.expectEqual(@as(usize, 1), unwind.walk(list.items, stopped(0x2000), handler, &pcs));
    try std.testing.expectEqual(@as(usize, 0), unwind.walk(list.items, stopped(0x1004), handler, pcs[0..0]));
}
