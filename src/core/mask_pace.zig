//! How wide a boundary is while a pend sits masked and the seam could not
//! step out of it.
//!
//! WHY THIS EXISTS. src/core/unmask.zig steps the core forward until
//! PRIMASK clears, which covers the ThreadX idle loop it was built for: a
//! masked window four instructions long. Past `unmask.limits.steps` it
//! gives up on purpose, because single-stepping a firmware through a long
//! bring-up mask is worse than waiting. What it does NOT do is remember
//! that it gave up. The pend is offered again at the next boundary, and
//! the next boundary is a whole chunk away.
//!
//! WHAT THAT COSTS, measured on `flash_journal` over 200 ms. Every one of
//! its 353 held pends is held for the same reason, PRIMASK, and the seam
//! cleared NONE of them: 353 lifts, 22592 instructions stepped, 64 each,
//! which is the bound exactly. So each one waited out a full 50000-
//! instruction chunk before anyone asked again, and the run entered
//! SysTick 183 times over 200 modelled periods. The firmware counts those
//! entries: `ra8_time_on_tick` is the only thing that moves `s_tick_ms`,
//! and `ra8_delay_ms` spins on it, so seventeen lost ticks are seventeen
//! milliseconds every delay in that image runs long.
//!
//! WHAT THIS DOES, and it is the same shape as src/core/pend_pace.zig:
//! shorten the BOUNDARY, do not force the pend. While lifts keep coming
//! back stuck, the next stretch runs 2000 instructions instead of the
//! configured chunk, so the mask is re-tested about twenty-five times as
//! often. Nothing is invented: the stretch is charged the instructions it
//! really runs, and the seam's own bound is untouched.
//!
//! IT DOES NOT WORK, and the number is the point. Behind `--pace-masked`
//! on the same image: 353 held pends become 8550, the instructions spent
//! inside lifts go from 22592 to 547200, twenty-four times the stepping,
//! and the run still enters SysTick 183 times. NOT ONE LIFT CLEARED. So
//! how OFTEN the mask is looked at was never the lever, exactly as
//! src/core/pend_look.zig found for a standing pend. It is kept, off by
//! default, so the next reader has the measurement rather than the idea.
//!
//! WHERE THE LEVER ACTUALLY IS, found while measuring this and not yet
//! acted on. Every stuck lift on this image ends at the same place, and
//! `ra8_delay_ms` disassembles into two branches: PRIMASK set spins on
//! DWT_CYCCNT at 0x02001740, PRIMASK clear spins on `s_tick_ms` with a
//! `wfi` at 0x02001770. The held pc is 0x02001772, INSIDE THE SECOND
//! BRANCH, which the firmware only reaches having read PRIMASK and found
//! it clear. The model is holding a pend masked at a pc the firmware
//! proved was unmasked. That is a disagreement about PRIMASK itself, not
//! about pacing, and no amount of looking more often fixes it.
//!
//! The run resets the moment a lift clears or no pend is masked at all,
//! so an image that never masks anything never pays for this.
const std = @import("std");

pub const limits = struct {
    /// The boundary width used while a masked pend keeps coming back
    /// stuck. The same 2000 as src/core/cadence.zig's `floor` and
    /// src/core/pend_pace.zig's `while_standing`, for the same reason:
    /// the narrowest this model runs a boundary at before per-boundary
    /// work dominates the run.
    pub const while_masked: u32 = 2_000;
};

/// The narrowing, and what it cost.
pub const Pace = struct {
    /// Off unless `--pace-masked` asks for it. The narrowing is measured
    /// to recover nothing (see the header), and switching it on changes
    /// the run, so the default path must not carry it.
    on: bool = false,
    /// Boundaries cut short because a masked pend was still stuck as they
    /// opened.
    narrowed: usize = 0,
    /// The longest run of stuck lifts that was still being narrowed for,
    /// so a reader can tell a mask held across one boundary from one held
    /// across a thousand.
    longest_run: u64 = 0,

    /// The width the next stretch gets: `configured` normally, the narrow
    /// one while `run` lifts in a row have ended stuck.
    ///
    /// A `configured` already at or inside the narrow width is returned
    /// untouched and NOT counted, the same rule pend_pace uses: a run cut
    /// that fine is already looking often enough, and counting it would
    /// read as work this did not do.
    pub fn widthFor(self: *Pace, configured: u32, run: u64) u32 {
        if (!self.on or run == 0 or configured <= limits.while_masked) return configured;
        self.narrowed +%= 1;
        if (run > self.longest_run) self.longest_run = run;
        return limits.while_masked;
    }

    /// Nothing to say: no boundary was ever narrowed.
    pub fn quiet(self: Pace) bool {
        return self.narrowed == 0;
    }
};
