//! The DWT comparator registers and the matches they make.
const std = @import("std");
const ra8 = @import("ra8");
const dwt = ra8.core.dwt;

const word_size: u32 = 2 << dwt.function_bits.size_shift;
const halts: u32 = dwt.function_bits.action_debug << dwt.function_bits.action_shift;

fn function(n: u32) u32 {
    return dwt.offsets.function0 + n * dwt.offsets.stride;
}

test "only the comparator registers are claimed, not CTRL or CYCCNT" {
    var unit = dwt.Dwt{};
    try std.testing.expect(!unit.write(0x000, 1));
    try std.testing.expect(!unit.write(0x004, 1));
    try std.testing.expect(!unit.write(dwt.offsets.comp0 + 4, 1));
    try std.testing.expect(!unit.write(dwt.limits.end, 1));
    try std.testing.expect(unit.write(dwt.offsets.comp0 + dwt.offsets.stride, 0x2000_0040));
    try std.testing.expectEqual(@as(?u32, 0x2000_0040), unit.peek(dwt.offsets.comp0 + dwt.offsets.stride));
}

test "FUNCTION keeps MATCH, ACTION and DATAVSIZE and drops read-only bits" {
    var unit = dwt.Dwt{};
    try std.testing.expect(unit.write(function(0), 0xFFFF_FFFF));
    try std.testing.expectEqual(@as(?u32, dwt.function_bits.writable), unit.peek(function(0)));
}

test "a halting data write comparator matches a store and sets MATCHED" {
    var unit = dwt.Dwt{};
    _ = unit.write(dwt.offsets.comp0, 0x2000_1000);
    _ = unit.write(function(0), dwt.match.data_write | halts | word_size);
    try std.testing.expectEqual(@as(?usize, null), unit.access(0x2000_1000, 4, .read));
    try std.testing.expectEqual(@as(?usize, null), unit.access(0x2000_1004, 4, .write));
    try std.testing.expectEqual(@as(?usize, 0), unit.access(0x2000_1002, 1, .write));
    try std.testing.expect(unit.peek(function(0)).? & dwt.function_bits.matched != 0);
}

test "a trigger-only comparator sets MATCHED without halting, and a read clears it" {
    var unit = dwt.Dwt{};
    _ = unit.write(dwt.offsets.comp0, 0x2000_1000);
    _ = unit.write(function(0), dwt.match.data | word_size);
    try std.testing.expectEqual(@as(?usize, null), unit.access(0x2000_1000, 4, .read));
    try std.testing.expect(unit.peek(function(0)).? & dwt.function_bits.matched != 0);
    unit.loaded(function(0));
    try std.testing.expectEqual(@as(u32, 0), unit.peek(function(0)).? & dwt.function_bits.matched);
}

test "an instruction address comparator matches the fetch, Thumb bit or not" {
    var unit = dwt.Dwt{};
    _ = unit.write(dwt.offsets.comp0, 0x0000_0200);
    _ = unit.write(function(0), dwt.match.instruction | halts | (1 << dwt.function_bits.size_shift));
    try std.testing.expectEqual(@as(?usize, null), unit.matchesPc(0x202));
    try std.testing.expectEqual(@as(?usize, 0), unit.matchesPc(0x201));
}
