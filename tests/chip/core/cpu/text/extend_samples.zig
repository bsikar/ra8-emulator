//! hw2 samples for the extend_wide and extend_b16 groups: every Rd and
//! every rotation, against Rm of r0, r3, ip, sp and pc.
pub const hw1_mask: u16 = 0xFF80;
pub const hw1_value: u16 = 0xFA00;

const rms = [_]u16{ 0, 3, 12, 13, 15 };

pub const hw2 = blk: {
    @setEvalBranchQuota(20_000);
    var out: [16 * 4 * rms.len]u16 = undefined;
    var n: usize = 0;
    for (0..16) |rd| {
        for (0..4) |rot| {
            for (rms) |rm| {
                out[n] = 0xF080 | (@as(u16, rd) << 8) | (@as(u16, rot) << 4) | rm;
                n += 1;
            }
        }
    }
    break :blk out;
};
