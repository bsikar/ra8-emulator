//! How finely modelled time advances: the boundary between chunks.
//!
//! Nothing inside this model moves on its own. Unicorn runs a stretch of
//! instructions with the peripherals frozen, and time passes only where that
//! stretch ends: the board ticks, a counter advances, a due event is raised,
//! and the controller picks. That end is a boundary, and how many
//! instructions sit between two of them is the whole resolution of modelled
//! time.
//!
//! dev runs 500000 instructions between boundaries (k_run_chunk_insns) and
//! this tree carried that number over. It is too coarse for the way firmware
//! actually waits. A driver polls a register inside a bounded loop, and the
//! bounds are counted in iterations rather than in time: ra8_epaper's LUT
//! wait gives up after 200000 reads, and the timer image in this tree gives
//! GTCNT 400000. A loop like that is a few instructions wide, so 400000
//! iterations is a couple of million instructions, which at a 500000-wide
//! boundary is three or four ticks in total. The counter the firmware is
//! watching moves three times while it is read four hundred thousand times,
//! and an image that would pass on the bench in microseconds burns its whole
//! budget and reports a timer that never arrived.
//!
//! The boundary is `instructions` wide instead, which puts the modelled
//! peripheral rate near the part rather than far below it: the GPT advances
//! `gpt.step_per_tick` (16385) per boundary, so a tenth of the old spacing is
//! about a third of a count per instruction, and silicon counting at PCLKD
//! against a core at roughly one instruction per cycle is the same order.
//! Nothing else changes: the clocks charge one instruction of time per
//! instruction executed either way, so a budget still buys the same number of
//! cycles, just delivered in smaller pieces.
const std = @import("std");

/// Instructions between two boundaries.
pub const instructions: u32 = 50_000;

/// The boundary policy of one run. A field rather than a bare constant so a
/// test can run a short boundary, which is also what the engine reads off the
/// time base.
pub const Cadence = struct {
    per_boundary: u32 = instructions,

    /// The next stretch to execute: a whole boundary, or whatever is left of
    /// the budget when less than one remains.
    pub fn chunk(self: Cadence, remaining: usize) usize {
        return @min(remaining, @as(usize, self.per_boundary));
    }

    /// Whether a boundary follows the stretch that leaves `remaining` behind.
    /// A spent budget does not get one: there would be no room to run what it
    /// raised, and a run that ended inside an exception it never entered is
    /// worse than one that ended a tick early.
    pub fn closes(_: Cadence, remaining: usize) bool {
        return remaining != 0;
    }

    /// How many boundaries a budget passes through, which is how many times
    /// the board ticks in a run of that length.
    pub fn boundaries(self: Cadence, budget: usize) usize {
        if (self.per_boundary == 0) return 0;
        const whole = budget / @as(usize, self.per_boundary);
        return if (budget % @as(usize, self.per_boundary) == 0 and whole > 0) whole - 1 else whole;
    }
};
