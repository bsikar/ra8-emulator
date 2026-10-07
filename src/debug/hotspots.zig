//! Where a run spent its instructions.
//!
//! A run that goes wrong rarely says so in a counter. It says so in the
//! program counter: four billion cycles elapsed, every peripheral counter
//! looks sane, and the whole of it went round one six-instruction spin
//! because the scheduler had nothing to dispatch. Nothing in the report
//! could tell that apart from a run that worked, and the only way to find
//! out was a throwaway print in the controller or a watchpoint on a word
//! the spin happened to touch.
//!
//! So the program counter is sampled once per chunk boundary, which is a
//! place the run loop already stops at, and the addresses that come up
//! most often are kept. One sample per boundary is cheap enough to leave
//! on for every run: a four-second image is about eighty thousand samples
//! over eighty thousand boundaries, which is plenty to separate a spin
//! from work and far too coarse to be a profiler. It is not one, and the
//! report says as much: these are samples, not counts of instructions.
//!
//! Its own file rather than a field on the session, because the policy
//! (how many addresses are worth keeping, what happens when a new one
//! arrives and the table is full) is the whole of the thing.

/// What the table costs and what it can hold.
pub const limits = struct {
    /// Addresses kept at once. Small on purpose: the question is which
    /// one or two places a run fell into, and a table that holds every
    /// address a working run touches answers a different question.
    pub const kept: usize = 16;
    /// Addresses reported. The rest are summed into the remainder.
    pub const listed: usize = 5;
    /// A site has to reach this share of the samples, in percent, before
    /// it is worth a line. Below it the reader learns nothing.
    pub const floor_percent: u64 = 1;
};

/// One address and how often the boundary landed on it.
pub const Site = struct {
    address: u32,
    samples: u64,
};

/// The sampled program counters of one run.
///
/// Full is not an error. When a new address arrives and every slot is
/// taken, the least-sampled slot is reused: a run that touches thousands
/// of addresses evenly has no hot site to report, and the slot churn is
/// the honest answer to that. A run that fell into a spin reaches its
/// site's count into the thousands within a few boundaries and nothing
/// can evict it after that.
pub const Table = struct {
    sites: [limits.kept]Site = @splat(.{ .address = 0, .samples = 0 }),
    used: usize = 0,
    /// Every sample taken, including those whose site was later evicted,
    /// so a share is a share of the run and not of the table.
    total: u64 = 0,
    /// Addresses that arrived to a full table and displaced a slot. A
    /// large number here is the signal that the top sites below are not
    /// the whole story.
    displaced: u64 = 0,

    /// Record one boundary's program counter.
    pub fn sample(self: *Table, pc: u32) void {
        self.total += 1;
        for (self.sites[0..self.used]) |*site| {
            if (site.address == pc) {
                site.samples += 1;
                return;
            }
        }
        if (self.used < limits.kept) {
            self.sites[self.used] = .{ .address = pc, .samples = 1 };
            self.used += 1;
            return;
        }
        self.displaced += 1;
        self.sites[self.weakest()] = .{ .address = pc, .samples = 1 };
    }

    /// The slot holding the fewest samples, which is the one a new
    /// address takes.
    fn weakest(self: *const Table) usize {
        var at: usize = 0;
        for (self.sites[0..self.used], 0..) |site, index| {
            if (site.samples < self.sites[at].samples) at = index;
        }
        return at;
    }

    /// The kept sites, most sampled first. Written into `into` rather
    /// than sorted in place, so asking does not change what a later
    /// sample sees.
    pub fn ranked(self: *const Table, into: *[limits.kept]Site) []const Site {
        @memcpy(into[0..self.used], self.sites[0..self.used]);
        const out = into[0..self.used];
        if (out.len < 2) return out;
        for (1..out.len) |index| {
            var at = index;
            while (at > 0 and out[at].samples > out[at - 1].samples) : (at -= 1) {
                const held = out[at - 1];
                out[at - 1] = out[at];
                out[at] = held;
            }
        }
        return out;
    }

    /// The share of the run's samples one site took, in percent.
    pub fn shareOf(self: *const Table, site: Site) u64 {
        if (self.total == 0) return 0;
        return site.samples * 100 / self.total;
    }

    /// Nothing worth printing: no samples, or no site that reached the
    /// floor. A run that spread itself evenly says so by being quiet.
    pub fn quiet(self: *const Table) bool {
        if (self.total == 0) return true;
        for (self.sites[0..self.used]) |site| {
            if (self.shareOf(site) >= limits.floor_percent) return false;
        }
        return true;
    }
};
