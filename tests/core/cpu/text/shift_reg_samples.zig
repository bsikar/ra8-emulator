//! hw2 samples for the shift_reg group: every Rd against every Rm.
pub const hw1_mask: u16 = 0xFF80;
pub const hw1_value: u16 = 0xFA00;

pub const hw2 = blk: {
    var out: [256]u16 = undefined;
    for (0..16) |rd| {
        for (0..16) |rm| out[rd * 16 + rm] = 0xF000 | (@as(u16, rd) << 8) | @as(u16, rm);
    }
    break :blk out;
};
