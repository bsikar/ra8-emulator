//! What the CPU model could not decode, and this emulator stepped by hand.
//!
//! The pinned Unicorn has no Armv8.1-M CPU model, so two families of
//! encoding a Cortex-M85 compiler emits freely are rejected by the core and
//! run off invalid-instruction hooks instead. Both lines are reported so a
//! run that leans on them says so, rather than the gap passing unnoticed.
const Writer = @import("report.zig").Writer;
const lob = @import("../core/lob.zig");
const csel = @import("../core/csel.zig");

/// Only when the hook was needed: a run of Armv8.0-M code says nothing here,
/// and a run of real Cortex-M85 code says how much of it the CPU model could
/// not reach on its own.
pub fn loops(out: Writer, stepped: lob.Loops) !void {
    if (stepped.quiet()) return;
    try out.print(
        "low-overhead loops: {d} stepped by hand, the CPU model cannot decode Armv8.1-M\n",
        .{stepped.stepped},
    );
}

/// The conditional selects, same reason and same shape. Counted apart from
/// the loops because they fail differently: a missed loop runs the body the
/// wrong number of times, a missed select stops the run dead.
pub fn selects(out: Writer, stepped: csel.Selects) !void {
    if (stepped.quiet()) return;
    try out.print(
        "conditional selects: {d} stepped by hand, the CPU model cannot decode Armv8.1-M\n",
        .{stepped.stepped},
    );
}
