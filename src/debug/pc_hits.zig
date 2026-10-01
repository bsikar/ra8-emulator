//! How many times a named instruction actually ran.
//!
//! Every other counter in the tree is a side effect of something else:
//! `--watch` counts stores that land in a word, the pend table counts
//! stores that found a pend already standing, a tally counts exceptions
//! taken. Each of those is one step removed from "did this instruction
//! execute, and how often", and when two of them disagree there is
//! nothing to settle it with.
//!
//! This is that something. A requested address is counted on every
//! execution and on nothing else. src/debug/hits_hook.zig is the other
//! half: this file knows nothing about Unicorn, so the counting can be
//! tested without a live engine.
const std = @import("std");

pub const limits = struct {
    /// Addresses a run can count at once. A code hook is attached per
    /// address and costs the blocks containing it, so this is deliberately
    /// small: the question it answers is always about a handful of
    /// instructions whose counts are supposed to agree.
    pub const places: usize = 4;
};

/// One counted address.
pub const Place = struct {
    /// The instruction's own address.
    at: u32 = 0,
    /// How many times it ran.
    hits: u64 = 0,
    /// Whether this slot was asked for at all.
    used: bool = false,
};

/// The counted addresses of one run.
pub const Hits = struct {
    places: [limits.places]Place = [_]Place{.{}} ** limits.places,
    /// Addresses asked for past the table's capacity.
    refused: usize = 0,

    /// Ask for an address to be counted. Asking twice for the same one is
    /// not an error and does not take a second slot: the count is per
    /// address, and a caller that names it twice means it once.
    pub fn want(self: *Hits, at: u32) void {
        for (&self.places) |*one| {
            if (one.used and one.at == at) return;
        }
        for (&self.places) |*one| {
            if (one.used) continue;
            one.* = .{ .at = at, .hits = 0, .used = true };
            return;
        }
        self.refused += 1;
    }

    /// Count one execution. An address that was never asked for is
    /// ignored rather than taking a slot, since the hook is only ever
    /// attached to addresses that were.
    pub fn hit(self: *Hits, at: u32) void {
        for (&self.places) |*one| {
            if (one.used and one.at == at) {
                one.hits += 1;
                return;
            }
        }
    }

    /// The addresses asked for, in the order they were asked for, so the
    /// report reads in the order the caller wrote them on the command line.
    pub fn asked(self: *const Hits) []const Place {
        var count: usize = 0;
        for (self.places) |one| {
            if (one.used) count += 1;
        }
        return self.places[0..count];
    }

    /// Whether this run counted nothing, so the report can stay silent.
    pub fn quiet(self: *const Hits) bool {
        return self.asked().len == 0 and self.refused == 0;
    }
};
