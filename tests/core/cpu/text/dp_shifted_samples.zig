//! hw2 samples for the dp_shifted group: every Rd, each with every shift
//! kind at amounts 0, 1, 10 and 31, and an Rm that moves with Rd.
pub const hw1_mask: u16 = 0xFE00;
pub const hw1_value: u16 = 0xEA00;

const amounts = [_]u16{ 0, 1, 10, 31 };

pub const hw2 = blk: {
    var out: [16 * 4 * amounts.len]u16 = undefined;
    var n: usize = 0;
    for (0..16) |rd| {
        const rm: u16 = (rd * 5 + 3) % 13;
        for (0..4) |kind| {
            for (amounts) |imm5| {
                const imm3 = imm5 >> 2;
                const imm2 = imm5 & 0x3;
                out[n] = (imm3 << 12) | (@as(u16, rd) << 8) | (imm2 << 6) | (@as(u16, kind) << 4) | rm;
                n += 1;
            }
        }
    }
    break :blk out;
};
