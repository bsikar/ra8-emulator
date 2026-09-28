//! The counter in RAM a run waits on.
//!
//! The firmware's emulator-in-the-loop suite checks a progress counter
//! rather than a printed line for a good half of its apps: it asks for
//! `--stop-sym <sym> <N>` and a passing app finishes as soon as the counter
//! named by `<sym>` has climbed to `<N>`, instead of burning the rest of the
//! instruction budget spinning in its idle loop.
//!
//! The word is read at a chunk boundary, the same place the clocks are
//! charged and an exception is taken, so the stop lands between
//! instructions and never inside one. Reading it is the engine's job, not
//! this file's: everything here is arithmetic over a value it is handed,
//! which is what keeps the core's only C boundary in one place.
const std = @import("std");

pub const Stop = struct {
    /// The address of the counter, resolved from the image's symbol table
    /// before the run starts.
    address: u32,
    /// The floor the counter has to reach. Reaching it exactly is enough,
    /// and climbing past it between two boundaries still counts: the suite
    /// asks for "at least N", never "exactly N".
    reaches: u32,
    /// Set when the run ended because the counter got there, which is what
    /// tells the report a stop was honoured rather than the budget spent.
    reached: bool = false,

    /// Has the counter climbed to its floor?
    ///
    /// An address that would not read is not a stop and is handed in as
    /// null: the run carries on to its instruction budget, which is the
    /// same outcome as a counter that never climbs. Treating an unreadable
    /// word as a met stop would report a pass for an app that faulted
    /// before it ever mapped its RAM.
    pub fn met(self: *Stop, seen: ?u32) bool {
        const value = seen orelse return false;
        if (value < self.reaches) return false;
        self.reached = true;
        return true;
    }
};
