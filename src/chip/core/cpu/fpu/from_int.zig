//! FixedToFP from the Arm ARM (DDI0553) for a 32-bit operand, the
//! arithmetic behind VCVT.F32/F64.S32/U32 (fbits 0) and, later, the
//! fixed-point forms. Zero converts to +0; anything else is
//! operand / 2^fbits through FPRound under the given mode, so only IXC
//! can be raised.
const format = @import("format.zig");
const Format = format.Format;
const round = @import("round.zig");
const fpscr_mod = @import("fpscr.zig");
const Fpscr = fpscr_mod.Fpscr;
const RMode = fpscr_mod.RMode;

pub fn fromFixed(comptime fmt: Format, op: u32, fbits: u6, unsigned: bool, mode: RMode, fpscr: *Fpscr) fmt.Bits() {
    const negative = !unsigned and op >> 31 == 1;
    const magnitude: u32 = if (negative) ~op +% 1 else op;
    if (magnitude == 0) return fmt.zero(0);
    const real: format.Real = .{ .sign = @intFromBool(negative), .mant = magnitude, .exp = -@as(i32, fbits) };
    return round.round(fmt, real, fpscr, mode);
}
