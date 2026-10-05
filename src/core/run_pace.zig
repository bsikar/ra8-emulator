//! How wide the next stretch is allowed to be.
//!
//! Its own file because it is policy over the run loop rather than part of
//! it: the run loop decides WHEN a boundary happens and what it
//! does, this decides how far apart boundaries are. Three things narrow a
//! stretch below the configured width, in this order: the SysTick period
//! the firmware armed, a pend standing unserved (src/core/pend_pace.zig),
//! and, only when asked for, a mask that keeps coming back stuck
//! (src/core/mask_pace.zig). Each only ever narrows.
const cadence = @import("cadence.zig");
const Session = @import("session.zig").Session;
const queue_pace = @import("queue_pace.zig");

/// The boundary this stretch gets. The armed period is read every time
/// round rather than once: the firmware arms SysTick well after reset,
/// and may re-arm it.
pub fn forStretch(core: anytype, configured: cadence.Cadence, session: Session) cadence.Cadence {
    var pace = configured;
    if (session.timebase) |clock| pace = pace.narrowedTo(clock.period(core));
    pace = queue_pace.narrowed(pace, session);
    pace = whileStanding(pace, session);
    // Narrowed again while a masked pend keeps coming back stuck, so the
    // mask is re-tested within a couple of thousand instructions instead
    // of a whole chunk. Off unless asked for: src/core/mask_pace.zig
    // carries the measurement that says it recovers nothing.
    if (session.mask_pace) |tracker| if (session.unmask) |seam| {
        pace = .{ .per_boundary = tracker.widthFor(pace.per_boundary, seam.run) };
    };
    return pace;
}

/// Narrow this boundary while a pend the firmware wrote is still standing
/// unserved, so the controller is asked again within a couple of thousand
/// instructions instead of a whole chunk.
///
/// Read off the controller's own run of unserved boundaries, which the
/// boundary just passed updated, so a pend that was entered puts the width
/// straight back. Nothing is forced and no time is invented: the stretch
/// is charged the instructions it actually runs, the same as any other.
/// src/core/pend_pace.zig carries why the boundary is the thing to shorten
/// and `--drain-pends` is not.
fn whileStanding(pace: cadence.Cadence, session: Session) cadence.Cadence {
    const tracker = session.pend_pace orelse return pace;
    const controller = session.interrupts orelse return pace;
    return .{ .per_boundary = tracker.widthFor(pace.per_boundary, controller.standing.run) };
}
