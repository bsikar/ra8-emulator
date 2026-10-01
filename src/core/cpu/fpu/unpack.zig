//! FPUnpack from the Arm ARM (DDI0553): classify an encoded value and, when
//! it is a nonzero number, give its exact real value. With FPSCR.FZ set, a
//! denormal input reads as a zero of the same sign and sets IDC, the input
//! denormal flag. NaNs are told apart by the top fraction bit: set is quiet.
const format = @import("format.zig");
const Format = format.Format;
const Real = format.Real;
const Fpscr = @import("fpscr.zig").Fpscr;

/// FPType in the pseudocode.
pub const Kind = enum { zero, nonzero, infinity, qnan, snan };

pub const Unpacked = struct {
    kind: Kind,
    sign: u1,
    /// The exact value; meaningful only when `kind` is `.nonzero`.
    real: Real = .{ .sign = 0, .mant = 0, .exp = 0 },
};

pub fn unpack(comptime fmt: Format, bits: fmt.Bits(), fpscr: *Fpscr) Unpacked {
    const F = fmt.frac_bits;
    const sign: u1 = @intCast(bits >> @intCast(fmt.width() - 1));
    const exp_field = (bits >> F) & fmt.expMask();
    const frac = bits & fmt.fracMask();
    if (exp_field == 0) {
        if (frac == 0) return .{ .kind = .zero, .sign = sign };
        if (fpscr.fz == 1) {
            fpscr.idc = 1;
            return .{ .kind = .zero, .sign = sign };
        }
        return nonzero(sign, frac, fmt.minExp() - F);
    }
    if (exp_field == fmt.expMask()) {
        if (frac == 0) return .{ .kind = .infinity, .sign = sign };
        const quiet = (frac >> (F - 1)) & 1 == 1;
        return .{ .kind = if (quiet) .qnan else .snan, .sign = sign };
    }
    const exp: i32 = @as(i32, @intCast(exp_field)) - fmt.bias() - F;
    return nonzero(sign, frac | (@as(fmt.Bits(), 1) << F), exp);
}

fn nonzero(sign: u1, mant: anytype, exp: i32) Unpacked {
    return .{ .kind = .nonzero, .sign = sign, .real = .{ .sign = sign, .mant = mant, .exp = exp } };
}
