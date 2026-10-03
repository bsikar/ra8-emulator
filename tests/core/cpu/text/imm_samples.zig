//! hw2 samples for the modified immediate groups: every Rd with immediates
//! that reach each expansion pattern (plain, 0x00XY00XY, 0xXY00XY00,
//! 0xXYXYXYXY) and the rotated form at its smallest and largest rotation.
pub const hw1_mask: u16 = 0xFA00;
pub const hw1_value: u16 = 0xF000;

const immediates = [_]u16{ 0x0005, 0x00FF, 0x1080, 0x200F, 0x30FF, 0x4080, 0x70FF };

pub const hw2 = blk: {
    var out: [16 * immediates.len]u16 = undefined;
    for (0..16) |rd| {
        for (immediates, 0..) |imm, k| out[rd * immediates.len + k] = imm | (@as(u16, rd) << 8);
    }
    break :blk out;
};
