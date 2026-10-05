//! The `timing` object of `--report json` (RA8EMU-383): the time base,
//! the idle seam, what the interrupt controller did with its pends, and the
//! PRIMASK waits, the same facts report/timing.zig prints in timing() and
//! controller(). The PendSV pend ledger is in json_pends.zig. Nothing
//! feeds it on the Zig core, so the object is null.
const clocks = @import("../../../periph/clocks.zig");
const nvic = @import("../../../periph/nvic.zig");
const idle = @import("../../../core/idle.zig");
const unmask = @import("../../../core/unmask.zig");
const pend_break = @import("../../../core/pend_break.zig");
const pend_pace = @import("../../../core/pend_pace.zig");
const mask_pace = @import("../../../core/mask_pace.zig");
const json_pends = @import("json_pends.zig");

/// What the run's timing hooks accumulated, copied off the report Tally.
pub const Timing = struct {
    timebase: clocks.Clocks,
    seam: idle.Seam,
    interrupts: nvic.Nvic,
    release: unmask.Release,
    pending: pend_break.Pend,
    pacing: pend_pace.Pace,
    masking: mask_pace.Pace,
};

/// The `timing` object, or null when the run collected none of it.
pub fn section(j: anytype, found: ?*const Timing) !void {
    const of = found orelse return j.field("timing", null);
    const base = of.timebase;
    try j.open("timing", '{');
    try j.field("elapsed", base.elapsed);
    try j.field("dwt_cycles", base.cycles);
    try j.field("systick_periods", base.ticks);
    try j.field("systick_pended", base.pends);
    try j.field("collapsed_periods", base.collapsed);
    try j.field("systick_rearms", base.rearms);
    try j.open("idle", '{');
    try j.field("skipped_cycles", of.seam.skipped);
    try j.field("closures", of.seam.closures);
    try j.field("boundaries", of.seam.boundaries);
    try j.close('}');
    try controller(j, &of.interrupts);
    try masked(j, of.release, of.masking);
    try json_pends.section(j, &of.pending, of.interrupts.standing.entries, of.pacing);
    try j.close('}');
}

fn controller(j: anytype, interrupts: *const nvic.Nvic) !void {
    const why = interrupts.why;
    try j.open("interrupts", '{');
    try j.field("taken", interrupts.taken);
    try j.field("returned", interrupts.returned);
    try j.field("held", interrupts.held);
    try j.field("chained", interrupts.chained);
    try j.field("held_masked", why.masked);
    try j.field("held_outranked", why.outranked);
    try j.field("held_too_deep", why.deep);
    try j.field("held_no_vector", why.no_vector);
    try j.field("first_waiting", if (why.waiting != 0) why.waiting else null);
    try j.field("first_waiting_on", if (why.waiting != 0) why.winner else null);
    const standing = interrupts.standing;
    try j.open("pendsv_standing", '{');
    try j.field("boundaries", standing.boundaries);
    try j.field("entries", standing.entries);
    try j.field("unserved", standing.unserved());
    try j.field("worst_run", standing.worst);
    try j.close('}');
    const passed = interrupts.passed;
    try j.open("passed", '{');
    try j.field("losses", passed.losses);
    try j.field("first_loser", if (passed.quiet()) null else passed.loser);
    try j.field("first_winner", if (passed.quiet()) null else passed.winner);
    try j.field("starved", if (passed.quiet()) null else passed.starved);
    try j.field("longest", passed.longest);
    try j.close('}');
    try j.close('}');
}

fn masked(j: anytype, release: unmask.Release, masking: mask_pace.Pace) !void {
    try j.open("mask", '{');
    try j.field("lifted", release.lifted);
    try j.field("stepped", release.stepped);
    try j.field("still_masked", release.stuck);
    try j.field("abandoned", release.faulted);
    try j.field("gave_up_booting", release.booting);
    try j.field("longest_lifts", release.longest);
    try j.field("longest_span", release.longest_held);
    try j.field("longest_stepped", release.longest_stepped);
    try j.field("paced_boundaries", masking.narrowed);
    try j.field("paced_worst_run", masking.longest_run);
    try j.close('}');
}
