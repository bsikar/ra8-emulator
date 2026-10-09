//! hw2 samples for the divide group: every Rd against every Rm.
pub const hw1_mask: u16 = 0xFFC0;
pub const hw1_value: u16 = 0xFB80;

pub const hw2 = blk: {
    @setEvalBranchQuota(20_000);
    var out: [256]u16 = undefined;
    for (0..16) |rd| {
        for (0..16) |rm| out[rd * 16 + rm] = 0xF0F0 | (@as(u16, rd) << 8) | @as(u16, rm);
    }
    break :blk out;
};
