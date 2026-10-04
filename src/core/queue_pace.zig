//! Close a boundary on the board's next queued event (RA8EMU-575).
//!
//! A timed block puts the virtual time its next event falls on onto the
//! board's queue (src/periph/time/event_queue.zig). Without this, that
//! event lands at the end of whichever boundary it falls inside, up to a
//! whole chunk late. Here the stretch is narrowed so it ends on the due
//! time, bounded by `cadence.floor` the same way the SysTick period is.
//!
//! Beside the run loop rather than in it: src/core/run_loop.zig belongs to
//! the dual-core work, and src/core/run_pace.zig is already where every
//! narrowing lives. Only ever narrows.
const std = @import("std");
const cadence = @import("cadence.zig");
const Session = @import("session.zig").Session;

/// `pace`, narrowed to end on the board's next queued event when that is
/// closer than the stretch would otherwise run.
pub fn narrowed(pace: cadence.Cadence, session: Session) cadence.Cadence {
    const tick = session.board orelse return pace;
    const cycles = tick.cyclesToDue();
    if (cycles == 0 or cycles > std.math.maxInt(u32)) return pace;
    return pace.narrowedTo(@intCast(cycles));
}
