//! The IEEE 754 binary formats FPv5 works in, and the exact real value the
//! Arm ARM (DDI0553) pseudocode computes with before FPRound turns it back
//! into bits. A Format names its exponent and fraction widths; everything
//! else (bias, masks, the bit type) follows from those two numbers, so single
//! and double precision share one implementation.
const std = @import("std");

pub const Format = struct {
    exp_bits: u5,
    frac_bits: u7,

    pub fn Bits(comptime self: Format) type {
        return std.meta.Int(.unsigned, 1 + @as(u16, self.exp_bits) + self.frac_bits);
    }

    pub fn width(comptime self: Format) u16 {
        return 1 + @as(u16, self.exp_bits) + self.frac_bits;
    }

    pub fn bias(comptime self: Format) i32 {
        return (@as(i32, 1) << (self.exp_bits - 1)) - 1;
    }

    /// The exponent of the smallest normal, -126 in single precision.
    pub fn minExp(comptime self: Format) i32 {
        return 1 - self.bias();
    }

    /// The all-ones exponent field that marks an infinity or a NaN.
    pub fn expMask(comptime self: Format) self.Bits() {
        return (@as(self.Bits(), 1) << self.exp_bits) - 1;
    }

    pub fn fracMask(comptime self: Format) self.Bits() {
        return (@as(self.Bits(), 1) << self.frac_bits) - 1;
    }

    pub fn pack(comptime self: Format, sign: u1, exp_field: self.Bits(), frac: self.Bits()) self.Bits() {
        const B = self.Bits();
        const top: std.math.Log2Int(B) = @intCast(self.width() - 1);
        return (@as(B, sign) << top) | (exp_field << self.frac_bits) | (frac & self.fracMask());
    }

    pub fn zero(comptime self: Format, sign: u1) self.Bits() {
        return self.pack(sign, 0, 0);
    }

    pub fn infinity(comptime self: Format, sign: u1) self.Bits() {
        return self.pack(sign, self.expMask(), 0);
    }

    /// The largest finite value, what an overflow rounds to when the rounding
    /// mode does not carry it to infinity.
    pub fn maxNormal(comptime self: Format, sign: u1) self.Bits() {
        return self.pack(sign, self.expMask() - 1, self.fracMask());
    }
};

pub const single: Format = .{ .exp_bits = 8, .frac_bits = 23 };
pub const double: Format = .{ .exp_bits = 11, .frac_bits = 52 };

/// A nonzero real number, exactly: (-1)^sign * mant * 2^exp. The pseudocode
/// works in unbounded reals; a 128-bit mantissa holds every exact
/// intermediate FPv5 needs (a double product is 106 bits).
pub const Real = struct {
    sign: u1,
    mant: u128,
    exp: i32,
};
