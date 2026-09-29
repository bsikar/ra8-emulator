//! OCTACLK: the clock the OSPI module-stop bits have to wait for.
//!
//! HUM Ch 11.2.7 "MSTPCRB" Note 3 (p 444) says MSTPB16 and MSTPB17, the two
//! per-instance OSPI module-stop bits, must be written AFTER the OCTACLK is
//! stable. ra8_system_regs.h quotes that note against OCTACKCR and names the
//! SREQ -> SRDY -> SREQ-clear handshake as "the documented way to confirm
//! stability"; ra8_xspi.c's block-level clock init carries the same citation
//! and is headed "run BEFORE the first MSTP release".
//!
//! It is not a prohibition with an unstated consequence. ra8_xspi.c records
//! what happens when the order is wrong, from the bench rather than from the
//! manual: without the handshake "the OSPI manual-command engine's internal
//! state machine cannot retire CDCTL0.TRREQ after the first CDBUF[0].CDT
//! write", and the symptom seen on HIL is every ra8_xspi_flash_* operation
//! surfacing as k_ra8_err_hw_timeout on CMDCMP, with flash_journal's
//! g_fj_match and g_fj_mismatch both reading 0 across the 5 s memprobe
//! window. So the release is not refused here: MSTPCRB takes the store the
//! way it always did, and the engine it uncovered is the thing that does not
//! work.
//!
//! OCTACKCR resets to 0x01, MOCO selected and never handshaken, so out of
//! reset the clock is NOT stable however much MOCO is running: what this
//! asks is whether the handshake has been driven, not what source is picked.
//! src/periph/ckcr.zig already models that handshake for all seven selects,
//! and one completed SREQ round on OCTACKCR is what makes the clock stable.
//! The state is read live off that model rather than copied, so a handshake
//! driven after an early release still counts for the next one.
//!
//! NOT MODELLED, AND NOT GUESSED: how far the wedge reaches. The one bench
//! symptom recorded is the manual-command engine, so that is all that stalls
//! here. Memory-mapped reads through the XSPI window, the second command
//! slot, and the calibration path are left alone, because nothing in this
//! tree says what they do. Nor does the wedge clear: nothing written down
//! says a late handshake un-sticks an engine that already came up wrong, so
//! once a run has released early it stays reported that way.
const ckcr = @import("ckcr.zig");

/// OCTACKCR, the select whose handshake declares OCTACLK stable.
pub const select_address: u32 = 0x4001_E075;

/// MSTPCRB is register index 1 of MSTPCRA..E.
pub const ospi_register: usize = 1;

/// MSTPB16 and MSTPB17, the two per-instance OSPI module-stop bits.
pub const ospi_bits: u32 = (1 << 16) | (1 << 17);

/// Whether the OSPI came out of module stop on a clock that was ready.
pub const Octa = struct {
    /// The board's live clock-select model, not a copy of it.
    clocks: *const ckcr.Ckcr,
    /// Releases of MSTPB16/B17 made before the handshake had completed.
    early_releases: u32 = 0,
    /// Set by the first such release and never cleared.
    wedged: bool = false,

    pub fn init(clocks: *const ckcr.Ckcr) Octa {
        return .{ .clocks = clocks };
    }

    pub fn quiet(self: *const Octa) bool {
        return self.early_releases == 0;
    }

    /// True once OCTACKCR has completed one SREQ -> SRDY -> SREQ-clear round.
    pub fn stable(self: *const Octa) bool {
        return self.clocks.completed(select_address) != 0;
    }

    /// One of the OSPI module-stop bits has just gone from stopped to
    /// running. On a clock nobody declared stable, the block is uncovered
    /// with its command engine unable to retire TRREQ.
    pub fn release(self: *Octa) void {
        if (self.stable()) return;
        self.early_releases +%= 1;
        self.wedged = true;
    }
};
