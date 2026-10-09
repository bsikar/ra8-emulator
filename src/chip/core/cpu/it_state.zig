//! EPSR.IT, the state an IT instruction leaves for the up to four
//! instructions it governs. IT[7:5] and the top of the condition sit at
//! xPSR[15:13], IT[4:2] at [12:10] and IT[1:0] at [26:25]. ITSTATE[7:4] is the
//! condition of the next instruction and ITSTATE[3:0] the mask of what is
//! left; a zero mask means no block.
pub const Itstate = u8;

const low_shift = 25;
const high_shift = 10;

/// ITSTATE out of an xPSR value.
pub fn get(xpsr: u32) Itstate {
    const low: u8 = @truncate((xpsr >> low_shift) & 0x3);
    const high: u8 = @truncate((xpsr >> high_shift) & 0x3F);
    return (high << 2) | low;
}

/// `xpsr` with its IT bits replaced by `state`.
pub fn put(xpsr: u32, state: Itstate) u32 {
    const cleared = xpsr & ~((@as(u32, 0x3) << low_shift) | (@as(u32, 0x3F) << high_shift));
    return cleared | (@as(u32, state & 0x3) << low_shift) | (@as(u32, state >> 2) << high_shift);
}

/// InITBlock(): whether an instruction is still governed.
pub fn active(state: Itstate) bool {
    return state & 0xF != 0;
}

/// The condition the next governed instruction runs under.
pub fn condition(state: Itstate) u4 {
    return @intCast(state >> 4);
}

/// ITAdvance(): the state after one governed instruction retires.
pub fn advance(state: Itstate) Itstate {
    if (state & 0x7 == 0) return 0;
    return (state & 0xE0) | ((state << 1) & 0x1F);
}
