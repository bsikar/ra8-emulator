// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Brighton Sikarskie
//! DWT_CYCCNT one instruction at a time, as a Cycle Counter comparator
//! sees it.
//!
//! src/chip/periph/clocks.zig charges the counter once per run-loop chunk, so
//! between two charges the word in memory stands still while instructions
//! run. A MATCH 0b0001 comparator is checked each time the counter is
//! written, directly or indirectly (DDI0553B.y D1.2.64), so a watch that
//! only saw the charges would stop up to a whole chunk late. This counts
//! the instructions run since the word last moved and adds them on, which
//! lands the stop on the instruction that brings the count to COMP0.
//!
//! The word moving under the count (a charge, a firmware store, a debugger
//! write) restarts it from the new value, so nothing is counted twice.

/// The count since DWT_CYCCNT last moved.
pub const Count = struct {
    /// The word as memory last read it.
    base: u32 = 0,
    /// Instructions run since `base` was read.
    ran: u32 = 0,
    /// Whether `base` holds a reading; false before the first one and
    /// after a halt wrote the count back.
    known: bool = false,

    /// The counter at this instruction, unrun, given the word memory holds
    /// now. Called once per instruction while a Cycle Counter watch is live.
    pub fn at(self: *Count, stored: u32) u32 {
        if (!self.known or stored != self.base) {
            self.base = stored;
            self.ran = 0;
            self.known = true;
        } else {
            self.ran +%= 1;
        }
        return self.base +% self.ran;
    }

    /// The run halted: the count to write back to DWT_CYCCNT, or null when
    /// nothing was counted. The engine stops before the instruction it
    /// halted on and runs it again on resume, so the next reading starts
    /// afresh from the word written here rather than counting it twice.
    pub fn settle(self: *Count) ?u32 {
        if (!self.known) return null;
        self.known = false;
        if (self.ran == 0) return null;
        return self.base +% self.ran;
    }

    /// No Cycle Counter watch is live any more.
    pub fn forget(self: *Count) void {
        self.known = false;
    }
};
