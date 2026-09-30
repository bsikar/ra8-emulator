//! Who wrote a watched place, counted rather than listed.
//!
//! A watch keeps the first few stores and the last few, and between them
//! it counts and drops. That is the right shape for a place written a
//! handful of times, and the wrong one for a place written hundreds of
//! times by a dozen sites: the question there is not "what happened at
//! the two ends" but "which sites write this, and how often each".
//!
//! Measured on `threadx_blink`, where `_tx_thread_preempt_disable` takes
//! 920 stores. The answer that located the freeze was a tally:
//! `_tx_thread_sleep+0xAE` writes 1 four hundred and fifty two times and
//! `_tx_thread_system_suspend+0x54` writes 0 four hundred and fifty one
//! times, so exactly one sleep never got its matching decrement. Neither
//! end of the list could show that, and getting it twice meant editing
//! the list length by hand and rebuilding. This is that tally, standing.
//!
//! Keyed on the PAIR (pc, value), not on the pc alone, because a site
//! that writes two different values is the interesting kind: on the same
//! run `_tx_thread_timeout+0x2C` writes 2 twice and 1 once, and folding
//! those together loses the shape of the end state.
//!
//! Its own file rather than a field on the watch, for the reason
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

/// One writing site and how often it wrote that value.
pub const Site = struct {
    pc: u32,
    value: u32,
    writes: u64,
};

/// The writing sites of one watched place.
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

    /// The slot holding the fewest writes, which a new pair takes.
    fn weakest(self: *const Tally) usize {
        var at: usize = 0;
        for (self.sites[0..self.used], 0..) |site, index| {
            if (site.writes < self.sites[at].writes) at = index;
        }
        return at;
    }

    /// The kept sites, most written first. Written into `into` so asking
    /// does not disturb what a later store sees.
    pub fn ranked(self: *const Tally, into: *[limits.kept]Site) []const Site {
        @memcpy(into[0..self.used], self.sites[0..self.used]);
        const out = into[0..self.used];
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
