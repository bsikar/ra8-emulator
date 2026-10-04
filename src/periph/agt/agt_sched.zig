//! When an AGT channel's next underflow is due on the virtual time base
//! (RA8EMU-179, slice RA8EMU-512).
//!
//! The AGT still counts `agt.step_per_tick` per chunk boundary, and a
//! boundary is `cadence.instructions` CPU0 cycles at the time base's rate.
//! So the PCLKB this model already counts at is that ratio, 2048 counts per
//! 50000 ns, 40.96 MHz. Deriving the rate from the stepping instead of
//! taking the part's real PCLKB is what keeps a queued underflow on the very
//! boundary the step lands it on, so moving the AGT onto the event queue
//! does not shift one line of the corpus. The clock tree slice (RA8EMU-515)
//! is where PCLKB becomes the part's real number.
const agt = @import("agt.zig");
const clk = @import("agt_clock.zig");
const cadence = @import("../../core/cadence.zig");
const timebase = @import("../time/timebase.zig");

/// The PCLKB rate the per-boundary step stands for.
pub const pclkb_hz: u64 = @as(u64, agt.step_per_tick) * timebase.default_hz / cadence.instructions;

/// The virtual ns channel `index` next underflows at, from `now_ns`. A
/// stopped channel and a cascaded one (it counts AGT0, not a clock) have
/// nothing due.
pub fn dueAt(channel: agt.Channel, index: usize, now_ns: u64) ?u64 {
    if (!channel.running()) return null;
    const in_ns = clk.underflowInNs(channel.counter, channel.source(index), pclkb_hz) orelse return null;
    return now_ns + in_ns;
}
