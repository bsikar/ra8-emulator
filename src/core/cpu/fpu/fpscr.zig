//! FPSCR, the floating-point status and control register, laid out as the
//! Arm ARM (DDI0553, "FPSCR") gives it for Armv8.1-M with MVE: the cumulative
//! exception flags in the low byte, LTPSIZE for tail predication, the
//! half-precision and single/double flush-to-zero controls, the rounding mode,
//! default NaN, alternative half precision, QC, and the NZCV compare flags.
//!
//! Field order is least significant bit first, so `@bitCast` to and from the
//! u32 VMRS and VMSR move is the register exactly.

/// FPSCR.RMode, the rounding mode the arithmetic uses unless an instruction
/// names its own.
pub const RMode = enum(u2) {
    /// Round to nearest, ties to even (RN).
    nearest = 0b00,
    /// Round towards plus infinity (RP).
    plus_inf = 0b01,
    /// Round towards minus infinity (RM).
    minus_inf = 0b10,
    /// Round towards zero (RZ).
    zero = 0b11,
};

pub const Fpscr = packed struct(u32) {
    /// Invalid operation, cumulative.
    ioc: u1 = 0,
    /// Division by zero, cumulative.
    dzc: u1 = 0,
    /// Overflow, cumulative.
    ofc: u1 = 0,
    /// Underflow, cumulative.
    ufc: u1 = 0,
    /// Inexact, cumulative.
    ixc: u1 = 0,
    _res5: u2 = 0,
    /// Input denormal, cumulative.
    idc: u1 = 0,
    _res8: u8 = 0,
    /// Tail-predication element size for low-overhead loops.
    ltpsize: u3 = 0b100,
    /// Flush-to-zero for half precision.
    fz16: u1 = 0,
    _res20: u2 = 0,
    rmode: RMode = .nearest,
    /// Flush-to-zero for single and double precision.
    fz: u1 = 0,
    /// Default NaN: NaN results are the default NaN, not a propagated input.
    dn: u1 = 0,
    /// Alternative half-precision format.
    ahp: u1 = 0,
    /// Cumulative saturation, set by saturating MVE operations.
    qc: u1 = 0,
    v: u1 = 0,
    c: u1 = 0,
    z: u1 = 0,
    n: u1 = 0,

    /// The register as VMRS reads it.
    pub fn bits(self: Fpscr) u32 {
        return @bitCast(self);
    }

    /// What VMRS APSR_nzcv, FPSCR copies into the APSR: N, Z, C and V in
    /// bits 31-28, the rest of the APSR value it returns zero.
    pub fn apsrNzcv(self: Fpscr) u32 {
        return self.bits() & 0xF000_0000;
    }

    /// Whether flush-to-zero applies to an operand or result of `width`
    /// bits: FZ16 for half precision, FZ for single and double.
    pub fn flushes(self: Fpscr, comptime width: u16) bool {
        return (if (width == 16) self.fz16 else self.fz) == 1;
    }

    /// The register as VMSR writes it, reserved bits read back as zero.
    pub fn fromBits(value: u32) Fpscr {
        return @bitCast(value & mask.writable);
    }
};

pub const mask = struct {
    /// Every bit FPSCR implements: the flags, LTPSIZE, FZ16, RMode, FZ, DN,
    /// AHP, QC and NZCV. Bits 5-6, 8-15 and 20-21 are reserved.
    pub const writable: u32 = 0xFFCF_009F;
    /// The cumulative exception flags, IOC to IXC and IDC.
    pub const cumulative: u32 = 0x0000_009F;
};
