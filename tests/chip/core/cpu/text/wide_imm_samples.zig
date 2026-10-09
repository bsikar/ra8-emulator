//! hw2 samples for the plain-immediate groups (MOVW, MOVT, ADDW, SUBW):
//! every Rd with immediates at zero, the decimal and hex boundary, and the
//! top of imm8 and imm3.
pub const hw1_mask: u16 = 0xFB00;
pub const hw1_value: u16 = 0xF200;

const immediates = [_]u16{ 0x0000, 0x0005, 0x0009, 0x000A, 0x00FF, 0x1000, 0x70FF };

pub const hw2 = blk: {
    var out: [16 * immediates.len]u16 = undefined;
    for (0..16) |rd| {
        for (immediates, 0..) |imm, k| out[rd * immediates.len + k] = imm | (@as(u16, rd) << 8);
    }
    break :blk out;
};
