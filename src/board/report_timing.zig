//! The time bases at the end of a run: what elapsed, what the firmware was
//! watching, and what it was never told about.
//!
//! Two cycle numbers rather than one, because they answer different
//! questions. How far the run got is a property of the run. What DWT_CYCCNT
//! holds is a property of the firmware, which only counts once it arms the
//! counter, and on this corpus most images never do. Printing only the
//! second made a run that covered two million instructions report zero.
//!
//! Its own file because the two counters it prints come from different models
//! (the time base in periph/clocks.zig, the controller in periph/nvic.zig) and
//! the interesting part is the relation between them, which belongs to neither.
const clocks = @import("../periph/clocks.zig");
const nvic = @import("../periph/nvic.zig");

const Writer = @import("report.zig").Writer;

/// A SysTick period is only worth anything to the firmware if something
/// raised for it. `collapsed` is how many wraps raised nothing, so a reader
/// can tell a slow run from a run whose clock is lying to it, and `rearms`
/// is the other side of the same ledger: stretches ended early to keep that
/// number down, each one a stretch whose cycles went uncharged.
pub fn timing(out: Writer, timebase: clocks.Clocks, interrupts: nvic.Nvic) !void {
    try out.print(
        "time: {d} cycles elapsed, {d} SysTick periods, {d} pended",
        .{ timebase.elapsed, timebase.ticks, timebase.pends },
    );
    if (timebase.collapsed != 0) {
        try out.print(
            ", {d} PERIOD(S) THE FIRMWARE WAS NEVER TOLD ABOUT",
            .{timebase.collapsed},
        );
    }
    try out.print("\n", .{});
    if (timebase.cycles != timebase.elapsed) {
        try out.print(
            "time: DWT_CYCCNT counted {d} of them; the firmware armed it late or never\n",
            .{timebase.cycles},
        );
    }
    if (timebase.rearms != 0) {
        try out.print(
            "time: {d} boundary(ies) ended where the firmware armed SysTick\n",
            .{timebase.rearms},
        );
    }
    try out.print(
        "interrupts: {d} taken, {d} returned, {d} held\n",
        .{ interrupts.taken, interrupts.returned, interrupts.held },
    );
}
