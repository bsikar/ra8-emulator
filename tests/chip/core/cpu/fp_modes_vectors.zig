//! Expected words for tests/fixtures/fpu/fp_modes.elf (RA8EMU-143), from
//! DDI0553 FPAdd, FPDiv, FPToFixed, FixedToFP, FPRoundInt, FPMul, FPSqrt
//! and FPMulAdd pseudocode. Each operation stores its result and then
//! FPSCR & 0x03C0009F, so the non-default control mode is checked too.
//!
//! Four RMode blocks (RN, RP, RM, RZ) each run +/- half-ULP addition,
//! +/-1/3 division and VCVTR of +/-2.5. Fixed-point conversions use #16
//! (and two 16-bit #8 cases). Then FZ and DN cases, five F16 arithmetic
//! ops, and FZ16 on a half subnormal. A done marker closes the run.

pub const words = [_]u32{
    0x3F80_0000, 0x0000_0010, 0xBF80_0000, 0x0000_0010,
    0x3EAA_AAAB, 0x0000_0010, 0xBEAA_AAAB, 0x0000_0010,
    0x0000_0002, 0x0000_0010, 0xFFFF_FFFE, 0x0000_0010,
    0x3F80_0001, 0x0040_0010, 0xBF80_0000, 0x0040_0010,
    0x3EAA_AAAB, 0x0040_0010, 0xBEAA_AAAA, 0x0040_0010,
    0x0000_0003, 0x0040_0010, 0xFFFF_FFFE, 0x0040_0010,
    0x3F80_0000, 0x0080_0010, 0xBF80_0001, 0x0080_0010,
    0x3EAA_AAAA, 0x0080_0010, 0xBEAA_AAAB, 0x0080_0010,
    0x0000_0002, 0x0080_0010, 0xFFFF_FFFD, 0x0080_0010,
    0x3F80_0000, 0x00C0_0010, 0xBF80_0000, 0x00C0_0010,
    0x3EAA_AAAA, 0x00C0_0010, 0xBEAA_AAAA, 0x00C0_0010,
    0x0000_0002, 0x00C0_0010, 0xFFFF_FFFE, 0x00C0_0010,
    0x0001_8000, 0x0000_0000, 0xFFFE_C000, 0x0000_0000,
    0x3FC0_0000, 0x0000_0000, 0xBFA0_0000, 0x0000_0000,
    0x0000_0180, 0x0000_0000, 0xFFFF_FF00, 0x0000_0000,
    0x0000_0000, 0x0100_0080, 0x7FC0_0000, 0x0200_0000,
    0x7FC0_0000, 0x0200_0001, 0x0000_4200, 0x0000_0000,
    0x0000_7C00, 0x0000_0014, 0x0000_3555, 0x0000_0010,
    0x0000_4000, 0x0000_0000, 0x0000_4700, 0x0000_0000,
    0x0000_0000, 0x0000_0000, 0x0F9C_0DE5,
};
