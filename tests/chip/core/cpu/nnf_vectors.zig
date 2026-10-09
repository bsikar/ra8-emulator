//! Expected words for tests/fixtures/fpu/nnf.elf (RA8EMU-321), worked on the
//! host from the plain loops in nnf.zig with IEEE single and half rounding to
//! nearest even, not from the core. Each trip count (0, 1, 5, 8, 13, 32)
//! stores eight words: an FNV-style hash of the fully-connected rows, of the
//! add/mul + ReLU output, the max, an FNV hash of the dequantized and of the
//! requantized values, the F16 dot product, the F16 dot after narrowing F32
//! into one operand, and an FNV hash after the abs-and-scale pass. A done
//! marker closes the run.

pub const words = [_]u32{
    0x9C00_0000, 0x0000_0000, 0xF149_F2CA, 0x0000_0000, 0x0000_0000, 0x0000_0000, 0x0000_0000, 0x0000_0000,
    0xB0E9_0000, 0x70E9_0000, 0xC0A0_0000, 0x7CB0_0000, 0xAFFF_8210, 0x0000_BC80, 0x0000_C2C0, 0x91C0_0000,
    0x32E0_5400, 0x4F0E_0000, 0xC060_0000, 0x9559_C000, 0x4E04_4450, 0x0000_C3F8, 0x0000_C9FA, 0x65C0_0000,
    0xEF64_A800, 0x37A3_8000, 0xC018_0000, 0x310B_0000, 0x2680_79D0, 0x0000_C4D8, 0x0000_CB44, 0x48C0_0000,
    0x6E8D_DE00, 0xC30A_8000, 0xBF00_0000, 0xFC5A_C000, 0x9030_D610, 0x0000_C514, 0x0000_CB9E, 0x7300_0000,
    0x684E_7000, 0x967B_9000, 0x40D4_0000, 0x644F_C000, 0xA651_6840, 0x0000_CE18, 0x0000_D493, 0xBB40_0000,
    0x0F9C_0DE5,
};
