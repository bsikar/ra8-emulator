//! ConditionPassed from the Arm ARM: whether a 4-bit condition holds against
//! APSR.NZCV. B<cond> uses it directly; IT will use it for each instruction
//! in the block.
const flags = @import("flags.zig");

pub fn passed(cond: u4, xpsr: u32) bool {
    const n = xpsr & flags.bits.n != 0;
    const z = xpsr & flags.bits.z != 0;
    const c = xpsr & flags.bits.c != 0;
    const v = xpsr & flags.bits.v != 0;
    const base = switch (cond >> 1) {
        0 => z, // EQ / NE
        1 => c, // CS / CC
        2 => n, // MI / PL
        3 => v, // VS / VC
        4 => c and !z, // HI / LS
        5 => n == v, // GE / LT
        6 => n == v and !z, // GT / LE
        else => true, // AL
    };
    // An odd condition inverts the even one, except 0b1111, which is AL too.
    if (cond & 1 != 0 and cond != 0xF) return !base;
    return base;
}
