//! The warm reboot: what performing a reset request does to the core.
//!
//! A block decides the part should reset (AIRCR.SYSRESETREQ today, a watchdog
//! underflow one day); the core is the engine's, so the board asks here and
//! the run loop performs it at the next chunk boundary.
//!
//! Performing it is deliberately small. SP and PC come back out of the vector
//! table, interrupts are unmasked, and any handler frames the run was inside
//! are abandoned. It is NOT a reload of the image: RAM survives the reset the
//! way it does on silicon, where a boot counter or a warm-start marker the
//! firmware parked in noinit memory is exactly what it wants to read on the
//! way back up. dev re-streams every PT_LOAD segment instead and wipes it.
//!
//! What this does not do is reset the peripherals. A system reset takes most
//! of the part back to its reset values; here every block keeps its state, so
//! a firmware that assumes a peripheral came back cold passes here and fails
//! on the bench. The board takes the interrupt latches down on its way past,
//! because a line still pending would be entered before the firmware has put
//! its vector table back, and the rest is named in the end-of-run report.

/// A pending reset: the board sets `requested`, the run loop performs it.
pub const Reboot = struct {
    /// Where the vector table is, so the part can come up out of it.
    vector_base: u32 = 0,
    requested: bool = false,
    /// Resets actually performed.
    performed: u32 = 0,

    /// Reset the core and report the address it comes up at. `interrupts` is
    /// the controller to abandon frames on, when the run has one.
    pub fn perform(self: *Reboot, core: anytype, interrupts: anytype) !u32 {
        self.requested = false;
        self.performed +%= 1;
        try core.resetFromVectorTable(self.vector_base);
        try core.setRegister(.primask, 0);
        if (interrupts) |controller| controller.depth = 0;
        return core.register(.pc);
    }
};
