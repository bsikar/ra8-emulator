//! hw2 samples for the saturate and sat16 groups: every Rd, each with
//! shift amounts 0, 1, 10 and 31 against six saturate positions. The
//! amount-0 rows below 16 are the sat16 encodings.
pub const hw1_mask: u16 = 0xFF00;
pub const hw1_value: u16 = 0xF300;

const amounts = [_]u16{ 0, 1, 10, 31 };
const sats = [_]u16{ 0, 8, 9, 15, 16, 31 };

pub const hw2 = blk: {
    @setEvalBranchQuota(20_000);
    var out: [16 * amounts.len * sats.len]u16 = undefined;
    var n: usize = 0;
    for (0..16) |rd| {
        for (amounts) |amount| {
            for (sats) |sat| {
                out[n] = ((amount >> 2) << 12) | (@as(u16, rd) << 8) | ((amount & 3) << 6) | sat;
                n += 1;
            }
        }
    }
    break :blk out;
};
