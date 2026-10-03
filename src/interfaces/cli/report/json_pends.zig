//! The `pends` object inside `timing` of `--report json` (RA8EMU-383):
//! the PendSV pend ledger, the boundaries paced while a switch stood, and
//! what became of every pend the firmware wrote by hand, the same facts
//! report/timing.zig prints in pends(), ledger() and paced(). Every key is
//! always present; an address is null until its counter is non-zero.
const pend_break = @import("../../../core/pend_break.zig");
const pend_pace = @import("../../../core/pend_pace.zig");
const pend_ledger = @import("../../../core/pend_ledger.zig");

/// The `pends` object. `entered` is the controller's PendSV entry count.
pub fn section(j: anytype, pending: *const pend_break.Pend, entered: u64, pacing: pend_pace.Pace) !void {
    const books = pend_ledger.Ledger{ .raised = pending.cuts, .entered = entered, .unpended = pending.cleared.count };
    try j.open("pends", '{');
    try j.open("ledger", '{');
    try j.field("raised", books.raised);
    try j.field("entered", books.entered);
    try j.field("unpended", books.unpended);
    try j.field("asks", pending.cuts + pending.swallowed);
    try j.field("balanced", books.balanced());
    try j.field("outstanding", books.outstanding());
    try j.field("phantom", books.phantom());
    try j.close('}');
    try j.field("paced_boundaries", pacing.narrowed);
    try j.field("paced_worst_run", pacing.longest_run);
    try j.field("cuts", pending.cuts);
    try swallowed(j, pending);
    try cleared(j, pending);
    try opened(j, pending);
    try j.field("stops", pending.stops);
    try j.field("stops_consumed", pending.consumed());
    try j.close('}');
}

fn swallowed(j: anytype, pending: *const pend_break.Pend) !void {
    try j.open("swallowed", '{');
    try j.field("count", pending.swallowed);
    try j.field("in_handler", pending.swallowed_in_handler);
    try j.field("longest_stretch", pending.longest_stretch);
    try j.field("stretches", pending.stretches);
    try j.field("first_at", if (pending.swallowed_placed) pending.swallowed_at else null);
    try j.field("elsewhere", pending.swallowed_elsewhere);
    try j.field("looks_given", pending.look.given);
    try j.field("looks_refused", pending.look.refused);
    try j.close('}');
}

fn cleared(j: anytype, pending: *const pend_break.Pend) !void {
    const down = pending.cleared;
    try j.open("cleared", '{');
    try j.field("count", down.count);
    try j.field("in_handler", down.in_handler);
    try j.field("without_pendsvclr", down.silent());
    try j.field("first_at", if (down.quiet()) null else down.first_at);
    try j.field("elsewhere", down.elsewhere);
    try j.close('}');
}

/// The four ways a stretch opened after the store that ended the last one.
fn opened(j: anytype, pending: *const pend_break.Pend) !void {
    try j.open("reentered", '{');
    try j.field("count", pending.reentered);
    try j.field("first_at", if (pending.reentered != 0) pending.reentered_at else null);
    try j.close('}');
    try j.open("handled", '{');
    try j.field("count", pending.handled);
    try j.field("first_exception", if (pending.handled != 0) pending.handled_exception else null);
    try j.field("first_at", if (pending.handled != 0) pending.handled_at else null);
    try j.field("first_from", if (pending.handled != 0) pending.handled_from else null);
    try j.close('}');
    try j.open("lift_moved", '{');
    try j.field("count", pending.lift_moved);
    try j.field("first_at", if (pending.lift_moved != 0) pending.lift_moved_at else null);
    try j.field("first_from", if (pending.lift_moved != 0) pending.lift_moved_from else null);
    try j.close('}');
    try j.open("reopened", '{');
    try j.field("count", pending.reopened);
    try j.field("first_at", if (pending.reopened != 0) pending.reopened_at else null);
    try j.field("first_from", if (pending.reopened != 0) pending.reopened_from else null);
    try j.close('}');
}
