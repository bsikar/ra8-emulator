//! Where lifts gave up with the pend still masked.
//!
//! Its own file because it answers a question the timing lines cannot:
//! those count give-ups, and a count alone reads the same whichever way
//! the model is wrong.
const elf = @import("../../core/elf.zig");
const symbols = @import("../../debug/symbols.zig");
const unmask = @import("../../core/unmask.zig");
const pend_sites = @import("../../core/pend_sites.zig");

/// Where lifts gave up with the pend still masked.
///
/// The count of give-ups is already on the interrupts line; this is the
/// code they stopped in, and it is the only thing that settles what the
/// mask MEANS. A firmware that masks on purpose and waits on something
/// else (ra8_delay_ms takes a DWT_CYCCNT spin when PRIMASK is set) gives
/// up inside that spin, and the model is right to hold the pend. A model
/// holding a mask the firmware already cleared gives up somewhere the
/// firmware believes interrupts are on. Same number, opposite fix, and
/// nothing else in the report tells them apart.
///
/// The same line splits them by WHEN as well as where. A give-up from
/// before the firmware had ever run unmasked is bring-up: the pend was
/// never takeable, because the machine had not yet reached the point
/// where it accepts interrupts, and the tick it would have carried was
/// never owed. A give-up after that instant is a critical section, which
/// is the only one worth arguing about.
///
/// And a third line says how FAR the worst one went, which is what
/// decides whether the bound is set anywhere near right. One give-up and
/// gone by the next boundary is a mask that overran the bound by less
/// than a chunk. Several in a row is a mask the model keeps failing to
/// wait out, and the stepped instructions under it are a floor rather
/// than its length: the ordinary stretches between those boundaries ran
/// under the same mask and are not counted.
pub fn maskSites(out: anytype, image: elf.Image, release: unmask.Release) !void {
    var sites = release.gave_up;
    if (sites.quiet()) return;
    try out.print(
        "interrupts: {d} of those give-up(s) came before the firmware first ran unmasked, {d} after\n",
        .{ release.booting, release.stuck - release.booting },
    );
    try out.print(
        "interrupts: the most stubborn mask outlasted {d} lift(s) in a row, {d} instruction(s) of stepping\n",
        .{ release.longest, release.longest_held },
    );
    for (sites.ranked()) |site| {
        try out.print(
            "interrupts: {d} lift(s) gave up still masked at pc 0x{X:0>8}",
            .{ site.count, site.pc },
        );
        if (symbols.inside(image, site.pc)) |at| {
            try out.print(" {s}+0x{X}", .{ at.name, at.offset });
        }
        try out.print("\n", .{});
    }
    if (sites.overflowed != 0) {
        try out.print(
            "interrupts: and {d} more from addresses past the {d} the table keeps\n",
            .{ sites.overflowed, pend_sites.limits.sites },
        );
    }
}
