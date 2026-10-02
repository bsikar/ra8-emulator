//! VPR and the predication it applies (RA8EMU-25). P0 (VPR bits 15:0)
//! has one bit per byte of a Q register; MASK01 (19:16) and MASK23
//! (23:20) count down the VPT block for beats 0-1 and 2-3. A predicated
//! write keeps the old byte wherever the effective mask bit is clear, and
//! an element counts as active by the bit of its lowest byte, as the
//! Arm ARM (DDI0553) pseudocode reads it.
const qreg = @import("qreg.zig");
const Size = qreg.Size;

pub const Vpr = packed struct(u32) {
    p0: u16 = 0,
    mask01: u4 = 0,
    mask23: u4 = 0,
    reserved: u8 = 0,
};

/// Each mask bit widened to a whole byte of the vector.
pub fn expand(mask: u16) u128 {
    var out: u128 = 0;
    for (0..16) |i| {
        if (mask >> @intCast(i) & 1 == 1) out |= @as(u128, 0xFF) << @intCast(8 * i);
    }
    return out;
}

/// `new` where the mask is set, `old` everywhere else.
pub fn merge(old: u128, new: u128, mask: u16) u128 {
    const m = expand(mask);
    return (new & m) | (old & ~m);
}

/// Whether element `e` of that size is active under the mask.
pub fn active(mask: u16, size: Size, e: u8) bool {
    const byte: u4 = @intCast(@as(u16, e) * (qreg.bits(size) / 8));
    return mask >> byte & 1 == 1;
}

/// The four mask bits beat `beat` (bytes 4*beat to 4*beat+3) runs under.
pub fn beatMask(mask: u16, beat: u2) u4 {
    return @truncate(mask >> (@as(u4, beat) * 4));
}
