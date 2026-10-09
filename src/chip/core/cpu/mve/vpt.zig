//! The VPT block state in VPR (RA8EMU-25). VPST and VPT write their 4-bit
//! mask into both MASK01 and MASK23. Every MVE instruction in the block
//! then advances it: a mask above 0b1000 (top bit set, more to come)
//! inverts that beat pair's P0 bits, so the next instruction runs the
//! other way, and then each mask shifts left one place. The block ends
//! when both masks reach zero. Outside a block a beat pair is not
//! predicated, so its element-mask bits read as all ones.
const Vpr = @import("predicate.zig").Vpr;

/// VPST or VPT: open a block. P0 is left as it stands.
pub fn open(vpr: Vpr, mask: u4) Vpr {
    var out = vpr;
    out.mask01 = mask;
    out.mask23 = mask;
    return out;
}

/// Opens only mask pairs whose odd beat has not completed.
/// DDI0553 E2.1.377 updates MASK01 on beat 1 and MASK23 on beat 3.
pub fn openBeats(vpr: Vpr, mask: u4, pending: u16) Vpr {
    var out = vpr;
    if (pending & 0x00F0 != 0) out.mask01 = mask;
    if (pending & 0xF000 != 0) out.mask23 = mask;
    return out;
}

/// Whether either beat pair is still in a VPT block.
pub fn inBlock(vpr: Vpr) bool {
    return vpr.mask01 != 0 or vpr.mask23 != 0;
}

/// The byte mask a predicated MVE instruction writes under: P0 for the
/// beat pairs in a block, all ones for the pairs outside one.
pub fn elementMask(vpr: Vpr) u16 {
    var mask = vpr.p0;
    if (vpr.mask01 == 0) mask |= 0x00FF;
    if (vpr.mask23 == 0) mask |= 0xFF00;
    return mask;
}

/// The state after one MVE instruction of the block has run.
pub fn advance(vpr: Vpr) Vpr {
    return advanceBeats(vpr, 0xFFFF);
}

/// advance() for an instruction that ran only the beats whose byte lanes
/// are set in `ran` (EPSR.ECI resumed it): only those P0 bits invert, and
/// MASK01 moves only when beat 1 ran. Beat 3 always runs.
pub fn advanceBeats(vpr: Vpr, ran: u16) Vpr {
    var out = vpr;
    var invert = ran;
    if (vpr.mask01 <= 0b1000) invert &= 0xFF00;
    if (vpr.mask23 <= 0b1000) invert &= 0x00FF;
    out.p0 ^= invert;
    if (ran & 0x00F0 != 0) out.mask01 = vpr.mask01 << 1;
    out.mask23 = vpr.mask23 << 1;
    return out;
}
