//! Which addresses stored a pend that was already standing.
//!
//! src/core/pend_break.zig counts those stores; this says where they came
//! from. The count alone cannot tell apart the two shapes that want
//! opposite fixes: one site asking over and over is a loop to go and read,
//! and the same count spread across the firmware is the model never
//! draining the bit at all.
//!
//! A FIXED TABLE, not a map. This is written from inside Unicorn's
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
    /// Stores from an address that arrived once the table was full.
    overflowed: usize = 0,

    /// Called from the hook: a swallowed store came from `pc`.
    pub fn record(self: *Sites, pc: u32) void {
        for (self.seen[0..self.used]) |*site| {
            if (site.pc != pc) continue;
            site.count +%= 1;
            return;
        }
        if (self.used == limits.sites) {
            self.overflowed +%= 1;
            return;
        }
        self.seen[self.used] = .{ .pc = pc, .count = 1 };
        self.used += 1;
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
