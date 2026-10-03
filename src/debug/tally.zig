//! A bounded tally of (key, value) pairs, most frequent first.
//!
//! Counting beats listing whenever a thing happens hundreds of times from
//! a handful of places. A list of the first few and the last few says what
//! a run opened and closed with; a tally says how the occurrences divide
//! up, and a division is what pairs one site against another.
//!
//! Measured on `threadx_blink`, where `_tx_thread_preempt_disable` takes
//! 920 stores. The answer that located the freeze was a tally:
//! `_tx_thread_sleep+0xAE` writes 1 four hundred and fifty two times and
//! `_tx_thread_system_suspend+0x54` writes 0 four hundred and fifty one
//! times, so exactly one sleep never got its matching decrement. Neither
//! end of the list could show that.
//!
//! Keyed on the PAIR, not on the key alone, because a site that produces
//! two different values is the interesting kind: on the same run
//! `_tx_thread_timeout+0x2C` writes 2 twice and 1 once, and folding those
//! together loses the shape of the end state.
//!
//! Two callers, and the second is why this is not named after the first.
//! src/debug/watchpoint.zig tallies (program counter, value written) to
//! say who wrote a watched place. src/core/run_loop.zig tallies
//! (interrupted program counter, exception number) to say where the
//! machine was when an exception was taken, which is the only way to ask
//! whether a context switch lands inside a window that must not be cut.
//!
//! Its own file rather than a field on either caller, for the reason
//! src/debug/hotspots.zig is its own file: the policy, what is kept and
//! what happens when the table fills, is the whole of the thing.

/// What the tally costs and what it can hold.
pub const limits = struct {
    /// Distinct (pc, value) pairs kept at once. A dozen sites is what a
    /// busy kernel word attracts, and a place written by more sites than
    /// this has no tally worth reading.
    pub const kept: usize = 16;
    /// Pairs reported, most frequent first.
    pub const listed: usize = 8;
};

/// One (key, value) pair and how often it occurred.
pub const Site = struct {
    /// What produced it: a program counter, in both callers so far.
    pc: u32,
    /// What it produced: a stored value, or an exception number.
    value: u32,
    /// How many times this exact pair occurred.
    writes: u64,
};

/// The pairs counted so far.
pub const Tally = struct {
    sites: [limits.kept]Site = [_]Site{.{ .pc = 0, .value = 0, .writes = 0 }} ** limits.kept,
    used: usize = 0,
    /// Pairs that arrived to a full table and displaced a slot, so a
    /// tally that is not the whole story says so.
    displaced: u64 = 0,

    /// Count one store.
    pub fn record(self: *Tally, pc: u32, value: u32) void {
        for (self.sites[0..self.used]) |*site| {
            if (site.pc == pc and site.value == value) {
                site.writes += 1;
                return;
            }
        }
        if (self.used < limits.kept) {
            self.sites[self.used] = .{ .pc = pc, .value = value, .writes = 1 };
            self.used += 1;
            return;
        }
        self.displaced += 1;
        self.sites[self.weakest()] = .{ .pc = pc, .value = value, .writes = 1 };
    }

    /// The slot holding the fewest occurrences, which a new pair takes.
    fn weakest(self: *const Tally) usize {
        var at: usize = 0;
        for (self.sites[0..self.used], 0..) |site, index| {
            if (site.writes < self.sites[at].writes) at = index;
        }
        return at;
    }

    /// The kept sites, most written first. Written into `into` so asking
    /// does not disturb what a later store sees. An empty tally ranks to an
    /// empty slice rather than tripping the 1.. range (RA8EMU-382).
    pub fn ranked(self: *const Tally, into: *[limits.kept]Site) []const Site {
        @memcpy(into[0..self.used], self.sites[0..self.used]);
        const out = into[0..self.used];
        if (out.len < 2) return out;
        for (1..out.len) |index| {
            var at = index;
            while (at > 0 and out[at].writes > out[at - 1].writes) : (at -= 1) {
                const held = out[at - 1];
                out[at - 1] = out[at];
                out[at] = held;
            }
        }
        return out;
    }

    /// A tally is worth printing only once more than one store landed:
    /// for a single store the list already says everything.
    pub fn quiet(self: *const Tally) bool {
        if (self.used == 0) return true;
        if (self.used > 1) return false;
        return self.sites[0].writes < 2;
    }
};
