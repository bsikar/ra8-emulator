//! The LUT busy status the host polls after a refresh, and the overlap it
//! exists to prevent.
//!
//! `ra8_epaper_display_area` sends DPY_AREA, sends its five argument words,
//! and then calls `internal_ra8_epaper_wait_lut_idle`, which reads LUTAFSR
//! (0x1224) in a bounded loop and returns as soon as the value is zero
//! (ra8_epaper.c on zig/dev, `k_ra8_epaper_lut_poll_max` 200000). That poll
//! is the whole handshake between a host and a film that takes hundreds of
//! milliseconds to settle.
//!
//! LUTAFSR here always read zero, so the loop exited on its first iteration
//! and a refresh was over the instant it was asked for. Two things followed
//! from that. A driver whose poll never actually runs is never exercised, so
//! a wait loop that would hang or time out on the bench looks clean. And a
//! second DPY_AREA clocked in while the film is still being driven was taken
//! as a second clean refresh, which on silicon is a command arriving at a
//! busy controller.
//!
//! So a refresh now holds the LUT busy and the poll runs it down.
//!
//! WHAT THE VALUE IS. The driver tests `status == 0U` and nothing else, and
//! no bit table for LUTAFSR is in either tree, so this answers a single busy
//! bit and does not pretend to name individual LUTs.
//!
//! WHAT THE DWELL IS. There is no wall clock on this panel: the model has no
//! notion of how long the film takes. The dwell is counted in polls, which
//! is the only thing the host does that the controller can see, and the
//! number is the model's own rather than any panel's. It is small on purpose:
//! enough that the driver's loop genuinely iterates, short enough that an
//! image which waits properly is never held up.
//!
//! WHAT IS NOT INVENTED. An overlapping command is COUNTED, not refused. The
//! IT8951 datasheet is not in this tree and nothing in either tree says the
//! controller drops a command that arrives mid-refresh, so the model reports
//! the overlap and still lets the command through. Refusing it would be a
//! hardware behaviour nobody here can cite.
//!
//! HRDY IS NOT THIS. The busy pin is the host-interface ready line and is
//! driven from the board; LUT busy is the film. The driver polls HRDY before
//! every preamble, including the preambles of the LUTAFSR read itself, so
//! holding that pin low for a refresh would deadlock the very poll that ends
//! it. It stays out of this model deliberately.

/// The modelled settling time, in host polls. See the header: this is the
/// model's own number, not a panel's.
pub const dwell = struct {
    /// Polls a DPY_AREA holds the LUT busy for.
    pub const refresh: u32 = 6;
};

/// What LUTAFSR answers. Zero is the idle the driver waits for; the busy
/// word is one bit, because one bit is all the driver reads.
pub const status = struct {
    pub const idle: u16 = 0x0000;
    pub const busy: u16 = 0x0001;
};

/// The LUT: busy or not, and how the host found out.
pub const Lut = struct {
    /// Polls still owed before the film has settled.
    remaining: u32 = 0,
    /// Refreshes that put the LUT into busy.
    started: u32 = 0,
    /// Refreshes that were polled all the way out to idle.
    settled: u32 = 0,
    /// LUTAFSR reads that answered busy.
    waited: u32 = 0,
    /// LUTAFSR reads that answered idle.
    cleared: u32 = 0,
    /// Commands that arrived with the film still being driven.
    overlapped: u32 = 0,

    /// True while the film is still being driven.
    pub fn busy(self: *const Lut) bool {
        return self.remaining != 0;
    }

    /// A run that never refreshed has nothing to narrate.
    pub fn quiet(self: *const Lut) bool {
        return self.started == 0 and self.overlapped == 0;
    }

    /// A refresh was asked for. A refresh asked for on top of one still in
    /// flight restarts the dwell, because the film is now being driven by
    /// the newer waveform.
    pub fn start(self: *Lut) void {
        self.started +%= 1;
        self.remaining = dwell.refresh;
    }

    /// LUTAFSR, read by the host. The read is what advances the dwell: it is
    /// the only thing the host does that the controller can see.
    pub fn poll(self: *Lut) u16 {
        if (self.remaining == 0) {
            self.cleared +%= 1;
            return status.idle;
        }
        self.waited +%= 1;
        self.remaining -= 1;
        if (self.remaining == 0) self.settled +%= 1;
        return status.busy;
    }

    /// A command reached the controller. Reports whether it landed on a busy
    /// film; the command itself is not refused, see the header.
    pub fn arrive(self: *Lut) bool {
        if (!self.busy()) return false;
        self.overlapped +%= 1;
        return true;
    }

    /// Refreshes asked for that the run never waited out. A non-zero answer
    /// is an image that walked away from the panel mid-refresh.
    pub fn unsettled(self: *const Lut) u32 {
        return self.started -| self.settled;
    }
};
