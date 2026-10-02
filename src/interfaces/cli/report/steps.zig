//! What the CPU model could not decode, and this emulator stepped by hand.
//!
//! The pinned Unicorn has no Armv8.1-M CPU model, so two families of
//! encoding a Cortex-M85 compiler emits freely are rejected by the core and
//! run off invalid-instruction hooks instead. Both lines are reported so a
//! run that leans on them says so, rather than the gap passing unnoticed.
const Writer = @import("../report.zig").Writer;
const lob = @import("../../../core/lob.zig");
const csel = @import("../../../core/csel.zig");
const tz = @import("../../../core/tz.zig");

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

/// The Secure to Non-Secure switch, the third thing this emulator steps by
/// hand and the one that changes where the run goes rather than what it
/// computes. An image with no secure boot in it says nothing. An image that
/// armed the seam says so either way: a boot that reached the switch is the
/// headline, and one that armed it and never got there is the more
/// interesting outcome of the two.
pub fn worlds(out: Writer, switched: tz.Worlds) !void {
    if (switched.quiet()) return;
    if (!switched.entered()) {
        try out.print(
            "TrustZone: Non-Secure entry armed at 0x{X:0>8}, never reached\n",
            .{switched.armed_at},
        );
        return;
    }
    if (switched.stack == 0) {
        try out.print(
            "TrustZone: entered the Non-Secure world at 0x{X:0>8} on the Secure stack, the Non-Secure vector table would not read\n",
            .{switched.entered_at},
        );
        return;
    }
    try out.print(
        "TrustZone: entered the Non-Secure world at 0x{X:0>8}, stack 0x{X:0>8}, {d} switch(es)\n",
        .{ switched.entered_at, switched.stack, switched.switched },
    );
}
