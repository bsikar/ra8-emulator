//! FPToFixed from the Arm ARM (DDI0553) for a 32-bit result, the
//! arithmetic behind VCVT and VCVTR to S32/U32 (fbits 0) and, later, the
//! fixed-point forms.
//!
//! The operand is unpacked (FZ flushes a denormal and sets IDC). A NaN
//! raises IOC and converts to 0; an infinity raises IOC and saturates.
//! Otherwise value * 2^fbits is rounded to an integer in the given mode
//! and saturated to the target range. Saturation raises IOC; an in-range
//! result that was rounded raises IXC instead.
const format = @import("format.zig");
const Format = format.Format;
const unpack_mod = @import("unpack.zig");
const round = @import("round.zig");
const Err = round.Err;
const fpscr_mod = @import("fpscr.zig");
const Fpscr = fpscr_mod.Fpscr;
const RMode = fpscr_mod.RMode;

pub fn toFixed(comptime fmt: Format, op: fmt.Bits(), fbits: u6, unsigned: bool, mode: RMode, fpscr: *Fpscr) u32 {
    const u = unpack_mod.unpack(fmt, op, fpscr);
    switch (u.kind) {
        .snan, .qnan => {
            fpscr.ioc = 1;
            return 0;
        },
        .zero => return 0,
        .infinity => {
            fpscr.ioc = 1;
            return saturate(u.sign, unsigned);
        },
        .nonzero => {},
    }
    const shift = u.real.exp + @as(i32, fbits);
    const len: i32 = 128 - @as(i32, @clz(u.real.mant));
    if (len + shift > 64) {
        fpscr.ioc = 1;
        return saturate(u.sign, unsigned);
    }
    const cut = round.scale(u.real.mant, shift);
    const magnitude = cut.int + @intFromBool(roundsUp(cut, u.sign, mode));
    const m: i128 = @intCast(magnitude);
    const value: i128 = if (u.sign == 1) -m else m;
    const lo: i128 = if (unsigned) 0 else -(1 << 31);
    const hi: i128 = if (unsigned) (1 << 32) - 1 else (1 << 31) - 1;
    if (value < lo or value > hi) {
        fpscr.ioc = 1;
        return saturate(@intFromBool(value < lo), unsigned);
    }
    if (cut.err != .none) fpscr.ixc = 1;
    return @truncate(@as(u128, @bitCast(value)));
}

/// Whether rounding the magnitude moves it up one: the pseudocode's
/// round_up on the signed value, restated for sign and magnitude.
pub fn roundsUp(cut: round.Cut, sign: u1, mode: RMode) bool {
    if (cut.err == .none) return false;
    return switch (mode) {
        .nearest => cut.err == .above_half or (cut.err == .half and cut.int & 1 == 1),
        .plus_inf => sign == 0,
        .minus_inf => sign == 1,
        .zero => false,
    };
}

/// The nearest end of the target range: the top for a positive overflow,
/// the bottom (0 when unsigned) for a negative one.
pub fn saturate(negative: u1, unsigned: bool) u32 {
    if (unsigned) return if (negative == 1) 0 else 0xFFFF_FFFF;
    return if (negative == 1) 0x8000_0000 else 0x7FFF_FFFF;
}
