//! ThumbExpandImm_C: the 12-bit "modified immediate" of the 32-bit data
//! processing encodings, i:imm3:imm8, turned into a 32-bit value and the
//! carry it leaves.
//!
//! A top two bits of zero repeat imm8 in one of four byte patterns and leave
//! the carry alone; a repeat of a zero byte is UNPREDICTABLE and comes back
//! null. Otherwise 1:imm12[6:0] is rotated right by imm12[11:7], and the
//! carry is bit 31 of the result.
const std = @import("std");
const shift = @import("shift.zig");
const Instr = @import("instr.zig").Instr;

pub fn imm12(instr: Instr) u12 {
    const i: u12 = @intCast((instr.hw1 >> 10) & 0x1);
    const imm3: u12 = @intCast((instr.hw2 >> 12) & 0x7);
    const imm8: u12 = @intCast(instr.hw2 & 0xFF);
    return (i << 11) | (imm3 << 8) | imm8;
}

pub fn expandC(imm: u12, carry_in: bool) ?shift.Shifted {
    const imm8: u32 = imm & 0xFF;
    if (imm >> 10 == 0) {
        const pattern: u2 = @intCast(imm >> 8);
        if (pattern != 0 and imm8 == 0) return null;
        const value: u32 = switch (pattern) {
            0 => imm8,
            1 => (imm8 << 16) | imm8,
            2 => (imm8 << 24) | (imm8 << 8),
            3 => imm8 *% 0x0101_0101,
        };
        return .{ .result = value, .carry = carry_in };
    }
    const unrotated: u32 = 0x80 | (imm & 0x7F);
    const rotated = std.math.rotr(u32, unrotated, @as(u5, @intCast(imm >> 7)));
    return .{ .result = rotated, .carry = rotated >> 31 != 0 };
}

/// Whether the encoding's immediate is one ThumbExpandImm accepts.
pub fn valid(instr: Instr) bool {
    return expandC(imm12(instr), false) != null;
}
