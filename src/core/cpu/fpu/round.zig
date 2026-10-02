//! FPRound from the Arm ARM (DDI0553), M-profile: an exact nonzero real to
//! the nearest representable value under a rounding mode, raising the
//! cumulative flags the pseudocode raises.
//!
//! - Underflow is detected before rounding: a tiny result that is inexact sets
//!   UFC, even when rounding carries it up to the smallest normal.
//! - With FPSCR.FZ set, a result whose exponent is below the smallest normal
//!   flushes to a zero of the same sign and sets UFC only, never IXC.
//! - Overflow sets OFC and IXC, and gives infinity or the largest finite
//!   value depending on the mode and the sign.
const format = @import("format.zig");
const Format = format.Format;
const Real = format.Real;
const fpscr_mod = @import("fpscr.zig");
const Fpscr = fpscr_mod.Fpscr;
const RMode = fpscr_mod.RMode;

/// Where the bits cut off below the rounding point sit, as a fraction of
/// one unit in the last place: the pseudocode's `error`.
pub const Err = enum { none, below_half, half, above_half };

pub const Cut = struct { int: u128, err: Err };

pub fn round(comptime fmt: Format, real: Real, fpscr: *Fpscr, mode: RMode) fmt.Bits() {
    const F = fmt.frac_bits;
    const min_exp = fmt.minExp();
    const exponent: i32 = @as(i32, 127 - @as(i32, @clz(real.mant))) + real.exp;
    if (fpscr.flushes(comptime fmt.width()) and exponent < min_exp) {
        fpscr.ufc = 1;
        return fmt.zero(real.sign);
    }
    var biased: i32 = if (exponent < min_exp) 0 else exponent - min_exp + 1;
    const cut = scale(real.mant, real.exp - (@max(exponent, min_exp) - F));
    var int_mant = cut.int;
    if (biased == 0 and cut.err != .none) fpscr.ufc = 1;
    if (roundsUp(mode, real.sign, cut.err, int_mant)) {
        int_mant += 1;
        if (int_mant == @as(u128, 1) << F) biased = 1;
        if (int_mant == @as(u128, 1) << (F + 1)) {
            biased += 1;
            int_mant >>= 1;
        }
    }
    if (biased >= fmt.expMask()) {
        fpscr.ofc = 1;
        fpscr.ixc = 1;
        return if (overflowsToInf(mode, real.sign)) fmt.infinity(real.sign) else fmt.maxNormal(real.sign);
    }
    if (cut.err != .none) fpscr.ixc = 1;
    return fmt.pack(real.sign, @intCast(biased), @intCast(int_mant & fmt.fracMask()));
}

fn roundsUp(mode: RMode, sign: u1, err: Err, int_mant: u128) bool {
    return switch (mode) {
        .nearest => err == .above_half or (err == .half and int_mant & 1 == 1),
        .plus_inf => err != .none and sign == 0,
        .minus_inf => err != .none and sign == 1,
        .zero => false,
    };
}

fn overflowsToInf(mode: RMode, sign: u1) bool {
    return switch (mode) {
        .nearest => true,
        .plus_inf => sign == 0,
        .minus_inf => sign == 1,
        .zero => false,
    };
}

/// mant * 2^shift split into its integer part and what was cut off below it.
pub fn scale(mant: u128, shift: i32) Cut {
    if (shift >= 0) return .{ .int = mant << @intCast(shift), .err = .none };
    const n: u32 = @intCast(-shift);
    if (n > 128) return .{ .int = 0, .err = .below_half };
    if (n == 128) return .{ .int = 0, .err = classify(mant, @as(u128, 1) << 127) };
    const rem = mant & ((@as(u128, 1) << @intCast(n)) - 1);
    return .{ .int = mant >> @intCast(n), .err = classify(rem, @as(u128, 1) << @intCast(n - 1)) };
}

fn classify(rem: u128, half: u128) Err {
    if (rem == 0) return .none;
    if (rem < half) return .below_half;
    if (rem == half) return .half;
    return .above_half;
}
