//! Whether PendSV's pend bit adds up: raised against disposed of.
//!
//! WHY THIS EXISTS. Two fires chased a leak that is not there. The standing
//! counter (src/periph/standing.zig) found the bit up at 18 chunk boundaries
//! on `wdt_supervisor_demo` against 376 stores that landed on one already
//! standing, and the clear counter (src/core/pend_clear.zig) then ruled the
//! firmware out as the thing taking it down. The reading that settles it is
//! neither of those: it is the one nobody had put side by side.
//!
//! The bit RISES 11 times in that run. It is entered 8 times and unpended by
//! the firmware 3 times. 8 + 3 = 11, and the same holds on the other images
//! that pend at all: 9 = 6 + 3 on `threadx_canfd_demo`, 3 = 3 + 0 on
//! `threadx_blink`. NOTHING IS LEAKING. Every pend the firmware raises is
//! accounted for.
//!
//! WHAT THAT MEANS FOR THE 387 STORES. ThreadX asks for a context switch 387
//! times and 376 of those asks land on a bit that is already up. That is the
//! architecture: PENDSVSET is a single flag and a second write to a standing
//! flag is genuinely a no-op on silicon too. The difference is how LONG it
//! stands. On the chip the handler is entered on the next instruction
//! boundary, so the flag is down again before the next ask arrives and each
//! ask gets its own switch. Here it stands until the next chunk boundary,
//! thousands of instructions later, and every ask that arrives in between
//! collapses into the one entry that eventually happens.
//!
//! So the hole is LATENCY, not accounting, and the number to drive down is
//! the stores-per-rise ratio (387 to 11, about 35 asks per switch served),
//! not some missing clear. `--drain-pends` is the existing attempt at that
//! and overshoots; whatever replaces it is measured against this ratio.
//!
//! This file exists so the balance is checked on every run rather than
//! reasoned about once. A non-zero residue here is a real leak and says so.
const std = @import("std");

/// One run's PendSV pend accounting.
pub const Ledger = struct {
    /// Stores that took the bit from down to up.
    raised: u64 = 0,
    /// Entries into the handler, each of which spends one rise.
    entered: u64 = 0,
    /// Stores by which the firmware took a standing bit back down itself.
    unpended: u64 = 0,

    /// Rises that have been neither entered nor unpended. At most one of
    /// these is honest: a bit still standing when the run ended.
    pub fn outstanding(self: Ledger) u64 {
        return self.raised -| (self.entered + self.unpended);
    }

    /// Disposals with no rise behind them, which would mean the model is
    /// entering or clearing a pend nobody asked for.
    pub fn phantom(self: Ledger) u64 {
        return (self.entered + self.unpended) -| self.raised;
    }

    /// The books close, allowing for one bit still up at the end.
    pub fn balanced(self: Ledger) bool {
        return self.phantom() == 0 and self.outstanding() <= 1;
    }

    /// How many asks the firmware made for each rise that was actually
    /// served, which is the latency reading this whole vein is about.
    /// Null when nothing was ever raised.
    pub fn asksPerRise(self: Ledger, stores: u64) ?f64 {
        if (self.raised == 0) return null;
        return @as(f64, @floatFromInt(stores)) / @as(f64, @floatFromInt(self.raised));
    }

    /// Nothing to say: this image never pended PendSV by hand.
    pub fn quiet(self: Ledger) bool {
        return self.raised == 0 and self.entered == 0 and self.unpended == 0;
    }
};
