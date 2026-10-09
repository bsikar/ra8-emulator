//! hw2 samples for the sat_arith group: hw2[15:12] of 0 and 0xF, every Rd,
//! every hw2[7:4], and Rm of r0, r3, ip and pc.
pub const hw1_mask: u16 = 0xFFF0;
pub const hw1_value: u16 = 0xFA80;

const tops = [_]u16{ 0x0, 0xF };
const rms = [_]u16{ 0, 3, 12, 15 };

pub const hw2 = blk: {
    @setEvalBranchQuota(40_000);
    var out: [tops.len * 16 * 16 * rms.len]u16 = undefined;
    var n: usize = 0;
    for (tops) |top| {
        for (0..16) |rd| {
            for (0..16) |mid| {
                for (rms) |rm| {
                    out[n] = (top << 12) | (@as(u16, rd) << 8) | (@as(u16, mid) << 4) | rm;
                    n += 1;
                }
            }
        }
    }
    break :blk out;
};
