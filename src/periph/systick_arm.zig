//! Whether a store into the SysTick window re-sizes the period the stretch
//! of execution in flight was cut from.
//!
//! Its own file because it is a decision, not a counter. `clocks.zig` holds
//! the time bases and charges them; this holds the one rule that says when a
//! stretch has to end early, and it needs no state at all to say so. The
//! engine cuts each stretch from the period armed when the stretch begins,
//! so a store that arms or re-sizes the period mid-stretch leaves the rest
//! of that stretch cut from a period the firmware has already replaced.
//!
//! A pure function over four words, so it is tested without an engine or a
//! clock: `src/core/cpu/systick_cut.zig` is the only caller and it supplies
//! them straight from the bus.
const memmap = @import("../core/memmap.zig");
const clocks = @import("clocks.zig");

/// What a store into the SysTick window means for the stretch in flight.
pub const Observed = enum { none, rearm };

/// Does this store re-size the period the stretch in flight was cut from?
///
/// `offset` and `word` are the store, `csr` and `rvr` the two registers as
/// they stand before it lands.
///
/// A RELOAD is only interesting while the counter runs. With the counter
/// stopped the period is zero either way, so the reload can be staged as
/// freely as the driver likes and nothing is owed; it is the store that
/// STARTS the counter which ends a stretch, and by then the reload beside it
/// is the one that will govern. `ra8_systick_configure` writes the reload,
/// then the counter, then the control word, which is exactly that order.
///
/// A RE-ARM while running is the retune path (`ra8_threadx_systick_retune`
/// reprogrammes SYST_RVR off the live CPUCLK0), and it ends a stretch only
/// when the reload actually moves: writing the same reload back leaves the
/// period where it was.
///
/// STOPPING the counter is deliberately not one of these. A stretch cut from
/// a period is never wider than the period, so finishing it swallows
/// nothing; the next one widens on its own once nothing is armed.
pub fn observe(offset: u32, word: u32, csr: u32, rvr: u32) Observed {
    const running = csr & clocks.csr_enable != 0;
    if (offset == memmap.syst.rvr) {
        if (!running) return .none;
        if (word & clocks.counter_mask == rvr & clocks.counter_mask) return .none;
        return .rearm;
    }
    if (offset == memmap.syst.csr) {
        if (running) return .none;
        if (word & clocks.csr_enable == 0) return .none;
        if (rvr & clocks.counter_mask == 0) return .none;
        return .rearm;
    }
    return .none;
}
