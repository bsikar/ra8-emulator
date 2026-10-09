//! Why a pend that was ready did not get taken.
//!
//! `Nvic.held` counts them all together, which is enough to notice that
//! something is being refused and not enough to act on. Four things refuse
//! a candidate and they want different fixes: PRIMASK is a seam question, a running handler of equal or better priority is
//! the architecture working correctly, the nesting guard is a model limit,
//! and a missing vector is the image's own business.
//!
//! WHAT THIS WAS BUILT FOR. `threadx_blink` runs its thread body about
//! three times per wake where the board runs it once, and the suspects
//! kept coming down to a pend that is raised and not taken. ThreadX sets
//! SHPR3 to 0x40FF0000, so SysTick runs at priority 0x40 and PendSV at
//! 0xFF: PendSV cannot preempt a SysTick handler and cannot win a boundary
//! against a fresh SysTick pend either. Which of those two is happening
//! was not readable from one number, and every fire re-derived it by
//! sweeping something. Now the run says it.
const std = @import("std");

/// One counter per reason a candidate was refused.
pub const Held = struct {
    /// PRIMASK was set.
    masked: u64 = 0,
    /// A handler of equal or better priority is already running, so the
    /// architecture would not take this one either.
    outranked: u64 = 0,
    /// The model's nesting guard, not anything the architecture does.
    deep: u64 = 0,
    /// The image has no handler for what it pended. Keeping the pend beats
    /// jumping to address zero.
    no_vector: u64 = 0,

    /// The exception refused for being outranked, the first time it
    /// happened, and what was running. Zero when it never did.
    waiting: u16 = 0,
    /// The exception that was running when `waiting` was first refused.
    winner: u16 = 0,

    pub fn total(self: *const Held) u64 {
        return self.masked + self.outranked + self.deep + self.no_vector;
    }

    /// Record a refusal for being outranked, keeping the first pairing.
    pub fn outrankedBy(self: *Held, candidate: u16, running: u16) void {
        self.outranked +%= 1;
        if (self.waiting != 0) return;
        self.waiting = candidate;
        self.winner = running;
    }

    pub fn quiet(self: *const Held) bool {
        return self.total() == 0;
    }
};
