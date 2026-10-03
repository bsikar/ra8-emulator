//! FPCCR, FPCAR and FPDSCR at 0xE000_EF34/38/3C (RA8EMU-328): the SCB words
//! that reach the FP context state in fpu/context.zig. A word read returns
//! the modelled register; a word write goes through the context's masks.
//! Anything else in the PPB is not this file's, and narrower accesses to
//! these three words are left to plain PPB RAM.
//!
//! Not modelled here: the Secure/Non-secure banking (RA8EMU-165), and the
//! privileged-only rule, since the Zig bus carries no privilege yet.
const State = @import("state.zig").State;

pub const address = struct {
    pub const fpccr: u32 = 0xE000_EF34;
    pub const fpcar: u32 = 0xE000_EF38;
    pub const fpdscr: u32 = 0xE000_EF3C;
};

pub const width: usize = 4;

/// The register at `at` as software reads it, or null when `at` is none
/// of the three.
pub fn read(state: *const State, at: u32) ?u32 {
    return switch (at) {
        address.fpccr => state.context.readFpccr(),
        address.fpcar => state.context.fpcar,
        address.fpdscr => state.context.fpdscr,
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
        else => return false,
    }
    return true;
}
