//! Expected words for tests/fixtures/fpu/dsp.elf (RA8EMU-116), worked on the
//! host from the plain loops in dsp.zig, not from the core. Each trip count
//! (0, 1, 7, 8, 9, 31, 64) stores eight words: the q15 dot product >> 6, the
//! q31 dot product, the sum of the saturating q15 add, the sum of the
//! saturating q7 add, the sum after the q31 scale, the q15 max, the sum of
//! the 8-tap q15 FIR over min(n, 56) outputs and the fused f32 dot product's
//! bits. A done marker closes the run.

pub const words = [_]u32{
    0x0000_0000, 0x0000_0000, 0x0000_0000, 0x0000_0000, 0x0000_0000, 0xFFFF_8000, 0x0000_0000, 0x0000_0000,
    0x001F_DB48, 0x0000_0000, 0x0000_7FFF, 0x0000_007F, 0x0000_0000, 0x0000_7001, 0xFFFF_B04A, 0xC090_0000,
    0xFF9B_7BEA, 0xE5CF_3888, 0xFFFF_E5E3, 0xFFFF_FFFE, 0xFC25_9350, 0x0000_7001, 0x0000_0BCE, 0xC194_C000,
    0xFF60_95EE, 0x74DC_E5E5, 0xFFFF_D548, 0x0000_001E, 0x3733_C026, 0x0000_7001, 0x0000_6539, 0xC19B_0000,
    0xFF8D_7E84, 0x6A4D_C5F6, 0xFFFF_5548, 0xFFFF_FFBE, 0x2D1D_4206, 0x0000_7001, 0x0000_DBE9, 0xC19F_0000,
    0x017B_43A7, 0x2AA5_A1D9, 0x0000_3215, 0xFFFF_FF3A, 0x90D1_9B56, 0x0000_7C53, 0x0003_2452, 0xC2AC_7000,
    0x0190_030A, 0xC46D_9F8D, 0x0000_4E8E, 0x0000_00D3, 0xF821_2536, 0x0000_7C53, 0x0006_BD8F, 0xC4B4_6000,
    0x0F9C_0DE5,
};
