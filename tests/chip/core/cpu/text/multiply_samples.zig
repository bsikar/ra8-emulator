//! hw2 samples for the mul_acc and long_mul groups: every Rd (RdHi), with
//! Ra (RdLo) of r0, r4, sp and pc, op2 of 0 and 1, and Rm of r0, r3, ip
//! and pc.
pub const hw1_mask: u16 = 0xFF00;
pub const hw1_value: u16 = 0xFB00;

const tops = [_]u16{ 0, 4, 13, 15 };
const rms = [_]u16{ 0, 3, 12, 15 };

pub const hw2 = blk: {
    @setEvalBranchQuota(20_000);
    var out: [16 * tops.len * 2 * rms.len]u16 = undefined;
    var n: usize = 0;
    for (0..16) |rd| {
        for (tops) |top| {
            for (0..2) |op2| {
                for (rms) |rm| {
                    out[n] = (top << 12) | (@as(u16, rd) << 8) | (@as(u16, op2) << 4) | rm;
                    n += 1;
                }
            }
        }
    }
    break :blk out;
};
