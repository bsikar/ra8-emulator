//! How wide a boundary gets while a switch the firmware asked for still
//! stands.
//!
//! WHY THIS EXISTS. src/core/pend_ledger.zig settled that the pend books
//! close: every rise of `ICSR.PENDSVSET` is either entered or taken back
//! down by the firmware, on all 36 images. Nothing leaks. What it also
//! measured is the hole that is actually there: on `wdt_supervisor_demo`
//! ThreadX issues 387 stores to get 11 rises and 8 entries, so a served
//! switch carries 35.2 asks. On silicon that number is 1.0, because the
//! handler is entered on the instruction boundary after the store and the
//! flag is down before the next ask can arrive.
//!
//! So the gap is TIME, not accounting. src/core/pend_break.zig already
//! stops the stretch on the rising edge, which is why `threadx_blink`
//! reads 1.0. It cannot help when the bit rises and the controller then
//! declines to take it at that boundary, which happens for reasons that
//! are correct in themselves: PRIMASK was set across the store, a handler
//! of equal or higher priority was still active, or something more urgent
//! won the pick. The architecture takes the pend a few instructions after
//! whichever of those clears. Here the next look is a whole boundary away,
//! 50000 instructions by default, and the thread that asked to be switched
//! away from spends all of them running and asking again.
//!
//! THE FIX IS THE BOUNDARY, NOT THE DISPATCH. `--drain-pends` tries the
//! other side of this (force a look on every Thread-mode re-ask) and
//! overshoots badly: blink falls to 1 toggle where the board shows 2, and
//! the watchdog's refresh cadence goes from 0.7 periods to 100.0 against a
//! source asking for 50. Shortening the boundary invents nothing and
//! forces nothing. The controller still decides; it is simply asked again
//! within `limits.while_standing` instructions instead of within a whole
//! chunk. Modelled time is charged per instruction executed either way, so
//! a narrowed stretch costs exactly the time it runs.
const std = @import("std");

pub const limits = struct {
    /// The boundary width used while a pend stands unserved.
    ///
    /// The same 2000 as src/core/cadence.zig's `floor`, and for the same
    /// reason: it is the narrowest this model will run a boundary at
    /// before per-boundary work dominates the run. Deliberately not
    /// narrower. The point is to bound the wait, not to single-step the
    /// firmware, and a wait bounded at 2000 instructions is already a
    /// twenty-fifth of the default chunk.
    pub const while_standing: u32 = 2_000;
};

/// The narrowing, and what it cost.
pub const Pace = struct {
    /// Boundaries cut short because a pend was standing as they opened.
    narrowed: usize = 0,
    /// The longest unserved run that was still being narrowed for, so a
    /// reader can tell a pend that waits one boundary from one that waits
    /// a thousand.
    longest_run: u64 = 0,

    /// The width the next stretch gets: `configured` normally, the narrow
    /// one while `run` boundaries have passed with the bit up and nothing
    /// entered.
    ///
    /// A `configured` that is already at or inside the narrow width is
    /// returned untouched and NOT counted: a run cut that fine (a short
    /// SysTick period, or `--chunk`) is already looking often enough, and
    /// counting it would read as work this did that it did not do.
    pub fn widthFor(self: *Pace, configured: u32, run: u64) u32 {
        if (run == 0 or configured <= limits.while_standing) return configured;
        self.narrowed +%= 1;
        if (run > self.longest_run) self.longest_run = run;
        return limits.while_standing;
    }

    /// Nothing to say: no boundary was ever narrowed.
    pub fn quiet(self: Pace) bool {
        return self.narrowed == 0;
    }
};
