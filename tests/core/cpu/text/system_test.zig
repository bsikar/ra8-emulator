//! Covers the Armv8.0-M system printers against Capstone: src/core/cpu/text/
//! sg.zig, tt.zig, udf.zig, bkpt.zig and bxns.zig.
const std = @import("std");
const ra8 = @import("ra8");
const capstone = @import("capstone.zig");
const Instr = ra8.core.cpu.instr.Instr;
const disasm = ra8.core.cpu.decode.text.disasm;

test "SG prints the way Capstone does" {
    try capstone.expectWideGroupMatches("sg", 0xFFFF, 0xE97F, &.{ 0xE97F, 0xE97E });
}

/// Each T/A pairing with Rd r0, r2, r12, SP and PC, plus nonzero low bits.
const tt_hw2 = [_]u16{ 0xF000, 0xF040, 0xF080, 0xF0C0, 0xF200, 0xFC40, 0xFD80, 0xFFC0, 0xF001, 0xF03F };

test "TT, TTT, TTA and TTAT print the way Capstone does" {
    try capstone.expectWideGroupMatches("tt", 0xFFF0, 0xE840, &tt_hw2);
}

/// UDF #0xf9: Capstone 5 cannot decode it, so it is checked by name below.
const capstone_gap: u16 = 0xDEF9;

test "every other 16-bit udf encoding prints the way Capstone does" {
    try capstone.expectGroupMatchesExcept("udf", &.{capstone_gap});
}

test "UDF #0xf9, which Capstone cannot decode, prints its Arm name" {
    const instr: Instr = .{ .address = capstone.address, .hw1 = capstone_gap, .size = 2 };
    const ours = disasm.one(instr) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("udf #0xf9", ours.slice());
}

test "UDF.W prints the way Capstone does" {
    try capstone.expectWideGroupMatches("udf", 0xFFF0, 0xF7F0, &.{ 0xA000, 0xA009, 0xA00A, 0xA234, 0xAFFF, 0xB000 });
}

test "every 16-bit bkpt encoding prints the way Capstone does" {
    try capstone.expectGroupMatches("bkpt");
}

test "every 16-bit bxns encoding prints the way Capstone does" {
    try capstone.expectGroupMatches("bxns");
}
