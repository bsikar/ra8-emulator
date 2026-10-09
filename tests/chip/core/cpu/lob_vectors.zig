//! Expected words for tests/fixtures/fpu/lob.elf (RA8EMU-232), worked on the
//! host from the plain loops in lob.zig, not from the core. Each trip count
//! (0, 1, 3, 4, 5, 16, 17, 37, 64) stores five words: the word sum and byte
//! sum over n, the full sum of `other` after other[i] = words[i] + 3 *
//! other[i] over n, the full dot product of `halves` with itself after
//! halves[i] = halves[i] * 0x0105 + 7 over n, and the FNV-1a style hash of
//! words over n. A done marker closes the run.

pub const words = [_]u32{
    0x0000_0000, 0x0000_0000, 0xA0DA_0AE0, 0x0BDB_BCE0, 0x811C_9DC5,
    0x0000_0000, 0x0000_000B, 0xA0DA_0AE2, 0x0BE5_42BB, 0x050C_5D1F,
    0xDAA6_6D2B, 0x0000_0090, 0x9F07_3693, 0xF0CA_A533, 0xFF04_1860,
    0xB54C_DA56, 0x0000_010A, 0x9D34_6242, 0xBFF4_2330, 0x89BE_A511,
    0x2E2A_C13A, 0x0000_01A9, 0x4570_9C80, 0x6920_9543, 0xF443_FAAF,
    0x2A01_0EB8, 0x0000_0708, 0x57E8_DE08, 0xBDCB_8E60, 0xF358_8AF5,
    0x0D78_AA48, 0x0000_0763, 0xF8D9_C6FA, 0x9387_071B, 0xDF18_61FF,
    0x9C52_AB4A, 0x0000_11D9, 0x0C05_EB30, 0x9692_5703, 0xDB76_666F,
    0xF4DE_90E0, 0x0000_2020, 0xD76C_B180, 0xA37B_06E0, 0x6476_6F05,
    0x0F9C_0DE5,
};
