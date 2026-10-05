//! A small table of program counters and how often each came up.
//!
//! TWO CALLERS, the same question in both: a count on its own cannot tell
//! apart the two shapes that want opposite fixes, one site coming up over
//! and over (a loop to go and read) against the same count spread across
//! the firmware (something the model does everywhere).
//!
//! src/core/pend_break.zig counts stores that landed on a pend already
//! standing; this says where they came from. src/core/unmask.zig counts
//! lifts that gave up with the pend still masked; this says where the
//! stepping stopped. Guessing that second one from a nearby number is
//! exactly the mistake this table exists to stop: an exception's entry pc
//! says where the firmware WAS when a pend was taken, and reads as an
//! answer to where a lift gave up without being one.
//!
//! A FIXED TABLE, not a map. This is written from inside the
//! memory-write hook, which has no allocator and runs on every store the
//! firmware makes to the register. A handful of slots covers every
//! scheduler that writes `ICSR.PENDSVSET` by hand (ThreadX uses two), and
//! a store that finds no slot is counted rather than dropped quietly, so
//! an image with more sites than this says so instead of lying by
//! omission.
const std = @import("std");

pub const limits = struct {
    /// Slots kept. ThreadX writes PENDSVSET from two places; the rest of
    /// the room is for a scheduler that does not.
    pub const sites = 8;
};

/// One address and how many swallowed stores came from it.
pub const Site = struct {
    pc: u32 = 0,
    count: usize = 0,
};

/// The table itself.
pub const Sites = struct {
    seen: [limits.sites]Site = [_]Site{.{}} ** limits.sites,
    used: usize = 0,
    /// Records that arrived for a new address once the table was full, so
    /// a run with more sites than slots says so instead of lying by
    /// omission.
    overflowed: usize = 0,

    /// Count one record against `pc`.
    ///
    /// THE BUSIEST SITES SURVIVE, not the first eight seen. A full table
    /// that simply refused newcomers would answer the wrong question
    /// entirely: the sites that matter are usually the ones a loop keeps
    /// coming back to, and a loop entered late arrives after eight
    /// one-off addresses have taken every slot. So a new address takes
    /// the least-counted slot and inherits its count, which is the
    /// standard way to keep heavy hitters in fixed room. The consequence
    /// is stated rather than hidden: a surviving count is an upper bound,
    /// over by at most what the slot held when it was taken over, and
    /// exact whenever `overflowed` is zero.
    pub fn record(self: *Sites, pc: u32) void {
        for (self.seen[0..self.used]) |*site| {
            if (site.pc != pc) continue;
            site.count +%= 1;
            return;
        }
        if (self.used < limits.sites) {
            self.seen[self.used] = .{ .pc = pc, .count = 1 };
            self.used += 1;
            return;
        }
        self.overflowed +%= 1;
        var thinnest = &self.seen[0];
        for (self.seen[1..]) |*site| {
            if (site.count < thinnest.count) thinnest = site;
        }
        thinnest.* = .{ .pc = pc, .count = thinnest.count +% 1 };
    }

    /// The sites that were used, busiest first.
    ///
    /// Sorts in place, which is fine because this is a terminal read: the
    /// report asks once, after the run.
    pub fn ranked(self: *Sites) []const Site {
        std.mem.sort(Site, self.seen[0..self.used], {}, busier);
        return self.seen[0..self.used];
    }

    /// Nothing was ever stored, so there is nothing to print.
    pub fn quiet(self: Sites) bool {
        return self.used == 0;
    }

    fn busier(_: void, a: Site, b: Site) bool {
        return a.count > b.count;
    }
};
