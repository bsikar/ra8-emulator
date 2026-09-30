//! The SCKDIVCR / SCKDIVCR2 divider nibbles, and what each code divides by.
//!
//! (HUM Ch 9.2.6 "SCKDIVCR" and 9.2.7 "SCKDIVCR2".) Both registers are bags of
//! four-bit fields, one per clock domain, and each field holds a divider code
//! rather than a ratio. The shifts come from ra8_cgc_regs.h: the
//! ra8_sckdivcr_shift_t enum for the eight in SCKDIVCR, and
//! ra8_sckdivcr2_shift_t for the four in SCKDIVCR2.
//!
//! THE CODE IS AN EXPONENT. ra8_clock_div_t runs div_1 = 0 through div_64 = 6,
//! so a code of N divides by 2^N and the whole map is one shift. Codes above 6
//! are not in that enum and are not guessed here: `ratio` answers null for
//! them and the report says the code rather than inventing a divisor.
//!
//! This file is the decode alone. What the tree does with a programmed
//! divider, and the protection in front of the registers, is `sysclk.zig`.

/// Nibble positions in SCKDIVCR (ra8_sckdivcr_shift_t).
pub const shift = struct {
    pub const pckd: u5 = 0;
    pub const pckc: u5 = 4;
    pub const pckb: u5 = 8;
    pub const pcka: u5 = 12;
    pub const bck: u5 = 16;
    pub const pcke: u5 = 20;
    pub const ick: u5 = 24;
    pub const fck: u5 = 28;
};

/// Nibble positions in SCKDIVCR2 (ra8_sckdivcr2_shift_t).
pub const shift2 = struct {
    pub const cpuclk0: u5 = 0;
    pub const cpuclk1: u5 = 4;
    pub const npuclk: u5 = 8;
    pub const mriclk: u5 = 12;
};

/// The highest code ra8_clock_div_t defines (div_64). Above this the encoding
/// is not recorded in the firmware tree, so nothing here claims a ratio.
pub const code_max: u4 = 6;

/// What a divider code divides by, or null when the code is outside the
/// documented range.
pub fn ratio(code: u4) ?u32 {
    if (code > code_max) return null;
    return @as(u32, 1) << code;
}

/// One clock domain: the name the report uses and the nibble it reads.
pub const Domain = struct { name: []const u8, at: u5 };

/// SCKDIVCR's eight domains, fastest-named first so the report reads the way
/// the HUM table does.
pub const domains = [_]Domain{
    .{ .name = "FCLK", .at = shift.fck },
    .{ .name = "ICLK", .at = shift.ick },
    .{ .name = "PCLKE", .at = shift.pcke },
    .{ .name = "BCLK", .at = shift.bck },
    .{ .name = "PCLKA", .at = shift.pcka },
    .{ .name = "PCLKB", .at = shift.pckb },
    .{ .name = "PCLKC", .at = shift.pckc },
    .{ .name = "PCLKD", .at = shift.pckd },
};

/// SCKDIVCR2's four domains.
pub const domains2 = [_]Domain{
    .{ .name = "CPUCLK0", .at = shift2.cpuclk0 },
    .{ .name = "CPUCLK1", .at = shift2.cpuclk1 },
    .{ .name = "NPUCLK", .at = shift2.npuclk },
    .{ .name = "MRICLK", .at = shift2.mriclk },
};

/// The code sitting in one nibble of a divider word.
pub fn codeAt(word: u32, at: u5) u4 {
    return @truncate(word >> at);
}
