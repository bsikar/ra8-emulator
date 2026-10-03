//! The security attribution a lockstep run gives its Zig core (RA8EMU-388).
//!
//! Without one the core treats every address as Secure, so an SG reached
//! from Non-secure code (a TrustZone pair calling its veneers) took a
//! SecureFault on the Zig side only and the run diverged on HFSR. The
//! answer here comes from lockstep's own SAU, which the firmware's stores
//! program through the replay bus, and the RA8 IDAU. Lockstep keeps no
//! CPSCU, so the IDAU's SRAM answer is the bit-28 rule alone; the
//! SRAMSABARn split is a board-run detail lockstep does not model.
const sau = @import("../../../periph/sau.zig");
const SauSource = @import("../sau_source.zig").SauSource;

/// The RA8 IDAU with no SRAMSABARn words.
pub const ra8_idau: sau.idau.Map = .{};

/// The source over `unit`; take `.source()` from a copy that outlives the run.
pub fn over(unit: *const sau.Sau) SauSource {
    return .{ .unit = unit, .idau = &ra8_idau };
}
