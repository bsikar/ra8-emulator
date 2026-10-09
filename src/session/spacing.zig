//! How far apart in modelled time the stores to one place landed.
//!
//! A watched place prints its first few stores and its last few, and the
//! count in between. That is enough to name who writes and what, and it
//! hides the shape of the writing: forty stores dropped from the middle
//! could be evenly spread over the run or could be eight bursts of five.
//! Measured on `threadx_blink`, where `g_threadx_blink_tick` takes 48
//! stores and both ends show several landing in one period, the
//! difference between those two readings is the difference between a
//! sleep that expires early and a sleep that does not suspend at all.
//!
//! So each store is compared against the one before it. Stores in the
//! same period are counted together, the gaps between periods are
//! counted apart, and the two numbers say the shape in one line without
//! keeping a store list that grows with the run.
const std = @import("std");

/// The gaps between consecutive stores, in SysTick periods.
pub const Spacing = struct {
    /// The period the last store landed in.
    last: u64 = 0,
    /// Whether any store has been recorded, so the first one starts the
    /// sequence rather than opening a gap against period zero.
    started: bool = false,
    /// Stores that landed in the same period as the one before them.
    together: usize = 0,
    /// Stores that opened a gap, which is one fewer than the number of
    /// groups the run divides into.
    apart: usize = 0,
    /// The narrowest gap and the widest, in periods. Both stay zero
    /// until a gap happens.
    shortest: u64 = 0,
    longest: u64 = 0,
    /// Every gap added up, so the average is available without keeping
    /// them.
    total: u64 = 0,

    /// Fold in a store that landed in period `when`.
    pub fn record(self: *Spacing, when: u64) void {
        if (!self.started) {
            self.started = true;
            self.last = when;
            return;
        }
        const gap = when -| self.last;
        self.last = when;
        if (gap == 0) {
            self.together += 1;
            return;
        }
        if (self.apart == 0 or gap < self.shortest) self.shortest = gap;
        if (gap > self.longest) self.longest = gap;
        self.apart += 1;
        self.total += gap;
    }

    /// Nothing worth printing: fewer than two stores, so no gap exists.
    pub fn quiet(self: Spacing) bool {
        return self.together == 0 and self.apart == 0;
    }

    /// Runs of stores that share a period, which is every gap plus the
    /// group the run opened with.
    pub fn groups(self: Spacing) usize {
        return self.apart + 1;
    }

    /// The average gap, in periods, over the gaps that happened. Zero
    /// when every store landed in one period.
    pub fn mean(self: Spacing) u64 {
        if (self.apart == 0) return 0;
        return self.total / @as(u64, self.apart);
    }
};
