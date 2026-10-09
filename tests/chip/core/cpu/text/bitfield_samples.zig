//! hw2 samples for the bitfield group: every Rd, each with every lsb
//! against a spread of widthm1/msb values.
pub const hw1_mask: u16 = 0xFF00;
pub const hw1_value: u16 = 0xF300;

const tops = [_]u16{ 0, 4, 9, 15, 26, 31 };

pub const hw2 = blk: {
    @setEvalBranchQuota(20_000);
    var out: [16 * 32 * tops.len]u16 = undefined;
    var n: usize = 0;
    for (0..16) |rd| {
        for (0..32) |lsb| {
            for (tops) |top| {
                out[n] = (@as(u16, lsb >> 2) << 12) | (@as(u16, rd) << 8) | (@as(u16, lsb & 3) << 6) | top;
                n += 1;
            }
        }
    }
    break :blk out;
};
