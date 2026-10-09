//! hw2 samples for the dsp_mul16, dsp_mulhi and dsp_long_mul groups: every Rd, with Ra
//! of r0, r4, sp and pc, every value of hw2[7:4], and Rm of r0, r3, ip
//! and pc.
pub const hw1_mask: u16 = 0xFF80;
pub const hw1_value: u16 = 0xFB00;

const ras = [_]u16{ 0, 4, 13, 15 };
const rms = [_]u16{ 0, 3, 12, 15 };

pub const hw2 = blk: {
    @setEvalBranchQuota(40_000);
    var out: [16 * ras.len * 16 * rms.len]u16 = undefined;
    var n: usize = 0;
    for (0..16) |rd| {
        for (ras) |ra| {
            for (0..16) |mid| {
                for (rms) |rm| {
                    out[n] = (ra << 12) | (@as(u16, rd) << 8) | (@as(u16, mid) << 4) | rm;
                    n += 1;
                }
            }
        }
    }
    break :blk out;
};
