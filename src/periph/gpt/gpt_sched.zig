//! When a GPT channel's next overflow is due on the virtual time base
//! (RA8EMU-179, slice RA8EMU-513).
//!
//! The GPT still counts `step_per_tick` (0x4001) per chunk boundary at the
//! undivided clock, and a boundary is `cadence.instructions` CPU0 cycles at
//! the time base's rate. So the PCLKD this model already counts at is that
//! ratio, 16385 counts per 50000 ns, 327.7 MHz. Deriving the rate from the
//! stepping, as agt_sched.zig does for PCLKB, keeps a queued overflow on the
//! boundary the step lands it on. The clock tree slice (RA8EMU-515) is where
//! PCLKD becomes the part's real number.
//!
//! A triangle (GTCR.MD symmetric) has nothing due here yet: its peak is a
//! fold of the phase, not a wrap, and it gets its own slice.
const ch = @import("gpt_channel.zig");
const clk = @import("gpt_clock.zig");
const cadence = @import("../../core/cadence.zig");
const timebase = @import("../time/timebase.zig");

/// The PCLKD rate the per-boundary step stands for.
pub const pclkd_hz: u64 = @as(u64, ch.step_per_tick) * timebase.default_hz / cadence.instructions;

/// The virtual ns channel next overflows at, from `now_ns`. A stopped
/// channel and a triangle have nothing due.
pub fn dueAt(channel: ch.Channel, now_ns: u64) ?u64 {
    if (!channel.running()) return null;
    if (channel.shape().symmetric()) return null;
    const period = channel.periodOrDefault();
    const in_ns = clk.overflowInNs(channel.cnt, period, channel.source(), pclkd_hz) orelse return null;
    return now_ns + in_ns;
}
