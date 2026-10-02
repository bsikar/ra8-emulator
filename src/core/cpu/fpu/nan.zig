//! NaN handling from the Arm ARM (DDI0553): FPDefaultNaN, FPProcessNaN and
//! FPProcessNaNs. A signalling NaN operand is quietened and sets IOC; with
//! FPSCR.DN set the result is always the default NaN instead of a propagated
//! operand. Between two NaN operands, any signalling NaN beats any quiet one,
//! and the first operand beats the second.
const Format = @import("format.zig").Format;
const Kind = @import("unpack.zig").Kind;
const Fpscr = @import("fpscr.zig").Fpscr;

/// Positive, all-ones exponent, only the top fraction bit set:
/// 0x7FC00000 in single precision.
pub fn defaultNaN(comptime fmt: Format) fmt.Bits() {
    return fmt.pack(0, fmt.expMask(), quietBit(fmt));
}

pub fn quietBit(comptime fmt: Format) fmt.Bits() {
    return @as(fmt.Bits(), 1) << (fmt.frac_bits - 1);
}

pub fn processNaN(comptime fmt: Format, kind: Kind, op: fmt.Bits(), fpscr: *Fpscr) fmt.Bits() {
    var result = op;
    if (kind == .snan) {
        result |= quietBit(fmt);
        fpscr.ioc = 1;
    }
    if (fpscr.dn == 1) result = defaultNaN(fmt);
    return result;
}

/// The NaN result of a two-operand operation, or null when neither operand
/// is a NaN and the operation goes on to compute.
pub fn processNaNs(
    comptime fmt: Format,
    kind1: Kind,
    kind2: Kind,
    op1: fmt.Bits(),
    op2: fmt.Bits(),
    fpscr: *Fpscr,
) ?fmt.Bits() {
    if (kind1 == .snan) return processNaN(fmt, kind1, op1, fpscr);
    if (kind2 == .snan) return processNaN(fmt, kind2, op2, fpscr);
    if (kind1 == .qnan) return processNaN(fmt, kind1, op1, fpscr);
    if (kind2 == .qnan) return processNaN(fmt, kind2, op2, fpscr);
    return null;
}

/// The NaN result of a three-operand operation (FPProcessNaNs3), or null.
/// Any signalling NaN beats any quiet one; within each, the first operand
/// beats the second and the second beats the third.
pub fn processNaNs3(
    comptime fmt: Format,
    kinds: [3]Kind,
    ops: [3]fmt.Bits(),
    fpscr: *Fpscr,
) ?fmt.Bits() {
    for (kinds, ops) |kind, op| if (kind == .snan) return processNaN(fmt, kind, op, fpscr);
    for (kinds, ops) |kind, op| if (kind == .qnan) return processNaN(fmt, kind, op, fpscr);
    return null;
}
