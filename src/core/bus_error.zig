//! A refused access turned into the BusFault it raises on silicon.
//!
//! Without this, an access to memory nothing maps ends the run with a fault
//! report. On the part it is a precise BusFault: the firmware's handler runs,
//! reads BFSR and BFAR, and decides what to do. A run opts in through
//! `Session.bus_errors`; the default stays the report, so runs that never
//! asked behave exactly as before.
//!
//! The access comes from the watch latch, because Unicorn's error code does
//! not carry it (src/core/fault.zig). A fault with no access recorded, or a
//! run with no controller to enter the handler through, is left to end the
//! run as it always did, and so is one whose entry fails.

const fault = @import("fault.zig");
const bus_fault = @import("../periph/bus_fault.zig");
const Session = @import("session.zig").Session;

/// Raise the BusFault behind `taken` and return where to resume, or null
/// when this run does not raise them or the fault was not a refused access.
pub fn raised(core: anytype, session: Session, taken: fault.Fault) !?u32 {
    const tally = session.bus_errors orelse return null;
    const controller = session.interrupts orelse return null;
    const access = taken.access orelse return null;
    const kind: bus_fault.Kind = switch (access.kind) {
        .read => .read,
        .write => .write,
        .fetch => .fetch,
    };
    const route = bus_fault.raise(core, controller, kind, @truncate(access.address), taken.pc) catch return null;
    tally.raised +%= 1;
    if (route.escalated) tally.escalated +%= 1;
    if (session.watch) |watch| watch.clear();
    return try core.register(.pc);
}
