//! FPCCR, FPCAR and FPDSCR at 0xE000_EF34/38/3C (RA8EMU-328) and CPACR at
//! 0xE000_ED88 (RA8EMU-353): the SCB words that reach the FP state. CPACR
//! keeps only its CP10 and CP11 fields; the rest read as zero. A word read returns
//! the modelled register; a word write goes through the context's masks.
//! Anything else in the PPB is not this file's, and narrower accesses to
//! these three words are left to plain PPB RAM.
//!
//! Not modelled here: the Secure/Non-secure banking (RA8EMU-165), and the
//! privileged-only rule, since the Zig bus carries no privilege yet.
const State = @import("state.zig").State;

pub const address = struct {
    pub const cpacr: u32 = 0xE000_ED88;
    pub const fpccr: u32 = 0xE000_EF34;
    pub const fpcar: u32 = 0xE000_EF38;
    pub const fpdscr: u32 = 0xE000_EF3C;
};

pub const width: usize = 4;

/// The CPACR bits that exist: CP10 and CP11.
pub const cpacr_mask: u32 = 0x00F0_0000;

/// The register at `at` as software reads it, or null when `at` is none
/// of the three.
pub fn read(state: *const State, at: u32) ?u32 {
    return switch (at) {
        address.fpccr => state.context.readFpccr(),
        address.fpcar => state.context.fpcar,
        address.fpdscr => state.context.fpdscr,
        address.cpacr => state.cpacr,
        else => null,
    };
}

/// Write `value` to the register at `at`; false when `at` is none of the
/// three.
pub fn write(state: *State, at: u32, value: u32) bool {
    switch (at) {
        address.fpccr => state.context.writeFpccr(value),
        address.fpcar => state.context.writeFpcar(value),
        address.fpdscr => state.context.writeFpdscr(value),
        address.cpacr => state.cpacr = value & cpacr_mask,
        else => return false,
    }
    return true;
}
