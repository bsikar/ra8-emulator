//! How many second looks a standing pend is given before the thread gets
//! the processor back.
//!
//! WHY THIS EXISTS. src/core/pend_pace.zig shortened the boundary while a
//! switch stands unserved, which took `wdt_supervisor_demo` from 35.2 asks
//! per served switch to 22.4. It could go no further because narrowing
//! only helps ONCE A BOUNDARY HAS SEEN the bit standing, and the asks that
//! pile up inside the stretch the rise itself cut are untouched by it. On
//! `threadx_canfd_demo` that is all of them and its ratio did not move.
//!
//! The piles are tight: `wdt_supervisor_demo` carried 78 swallowed stores
//! inside one 2000-instruction stretch at worst, a store every 26
//! instructions. That is ThreadX calling `_tx_thread_system_suspend`,
//! pending a switch it does not get, returning to the thread, and coming
//! straight back. On silicon the first of those stores is followed by the
//! handler.
//!
//! WHAT THIS SLICE MEASURED, and it is a negative result worth keeping.
//! `--drain-pends` gives a look to EVERY Thread-mode re-ask and overshoots
//! badly, so the obvious next move is to bound the allowance. Two bounds
//! were built and run, and BOTH collapse into `--drain-pends` exactly:
//!
//!   one look per STRETCH: the look is what ENDS the stretch, so the next
//!   stretch opens immediately and hands the allowance straight back. Over
//!   200 ms of `wdt_supervisor_demo`: 2999 looks across 3001 stretches,
//!   none refused.
//!
//!   one look per RISE: the firmware raises the bit again as soon as the
//!   switch it just got is spent, so a rise carries about one swallowed
//!   store and the allowance is renewed just as fast. Same run: 6006
//!   stores over 3003 rises, 2.0 asks per rise, and the identical 2999
//!   looks.
//!
//! Both land on 3003 PendSV entries against the default path's 8, and
//! both leave `wdt_supervisor_demo` refreshing its watchdog twice in 200
//! ms with one underflow, where the firmware asks for a refresh every 50
//! SysTick periods. Counting the looks is therefore not the lever: the
//! ratio is not high because the look is rationed, and rationing it does
//! not make the run truer. The lever is what the controller does at the
//! boundary, which is the next slice's business.
//!
//! So this ships OFF, like the experiment it refines, and the default
//! path is bit-identical to before it. `--drain-pends` keeps its old
//! meaning and `--look-per-rise` adds the bounded one, so the next fire
//! can reproduce either against a board reading rather than re-deriving
//! them. A look costs one instruction and raises nothing: the bit was
//! already up, and all the boundary buys is a chance to dispatch it.
const std = @import("std");

/// How often a Thread-mode store that lands on a standing pend is allowed
/// to end the stretch.
pub const Policy = enum {
    /// Never. The default, and the only setting any image's behaviour
    /// depends on.
    off,
    /// The first re-ask after each rise, and no more until the next one.
    per_rise,
    /// Every re-ask, which is what `--drain-pends` has always meant.
    every,
};

/// The allowance, and what it spent.
pub const Look = struct {
    policy: Policy = .off,
    /// Whether the pend standing right now has already spent its look.
    spent: bool = false,
    /// Looks given, so the cost is readable rather than assumed.
    given: usize = 0,
    /// Re-asks that found the allowance already spent, so the pile behind
    /// one standing pend is readable against the one look it bought.
    refused: usize = 0,

    /// A Thread-mode store landed on a pend that was already standing:
    /// whether it ends the stretch.
    pub fn ask(self: *Look) bool {
        switch (self.policy) {
            .off => return false,
            .every => {},
            .per_rise => if (self.spent) {
                self.refused +%= 1;
                return false;
            },
        }
        self.spent = true;
        self.given +%= 1;
        return true;
    }

    /// A new pend was raised, so the switch it asks for gets its own look.
    pub fn rearm(self: *Look) void {
        self.spent = false;
    }

    /// Whether a stretch the hook stopped should be cut short for a look.
    pub fn cuts(self: Look) bool {
        return self.policy != .off;
    }

    /// Nothing to say: no look was ever given.
    pub fn quiet(self: Look) bool {
        return self.given == 0;
    }
};
