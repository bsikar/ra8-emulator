//! The rounding an operation applies, which is FPSCR's mode for most of
//! them but fixed by the encoding for VCVTA/N/P/M and VRINTA/N/P/M/Z.
//! Ties-away (the A forms) has no FPSCR encoding, so it is its own value.
const fpscr_mod = @import("fpscr.zig");
const RMode = fpscr_mod.RMode;
const round = @import("round.zig");

pub const Rounding = enum {
    nearest,
    plus_inf,
    minus_inf,
    zero,
    ties_away,

    /// The rounding FPSCR's mode field selects.
    pub fn of(mode: RMode) Rounding {
        return switch (mode) {
            .nearest => .nearest,
            .plus_inf => .plus_inf,
            .minus_inf => .minus_inf,
            .zero => .zero,
        };
    }
};

/// Whether rounding a cut magnitude moves it up one: the pseudocode's
/// round_up on the signed value, restated for sign and magnitude.
pub fn roundsUp(cut: round.Cut, sign: u1, rounding: Rounding) bool {
    if (cut.err == .none) return false;
    return switch (rounding) {
        .nearest => cut.err == .above_half or (cut.err == .half and cut.int & 1 == 1),
        .ties_away => cut.err == .half or cut.err == .above_half,
        .plus_inf => sign == 0,
        .minus_inf => sign == 1,
        .zero => false,
    };
}
