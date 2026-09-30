//! The time bases at the end of a run: what elapsed, what the firmware was
//! watching, and what it was never told about.
//!
//! Two cycle numbers rather than one, because they answer different
//! questions. How far the run got is a property of the run. What DWT_CYCCNT
//! holds is a property of the firmware, which only counts once it arms the
//! counter, and on this corpus most images never do. Printing only the
//! second made a run that covered two million instructions report zero.
//!
//! A third number when a run spent time in a spin: the cycles that were
//! charged without being executed, because the machine had been stepped back
//! to the state it started in and nothing it did on the way could be seen.
//! It is reported rather than hidden because it is the difference between a
//! run that idled and a run that worked, and the reader cannot tell them
//! apart from the elapsed count alone.
//!
//! A fourth when a pend had to wait out PRIMASK. The controller can only
//! take an exception at a chunk boundary, so a pend that lands inside a
//! `cpsid i` region is stepped to the unmask rather than dropped until the
//! next period; how often that happened, and what it cost in instructions,
//! is the difference between a scheduler that runs and one that starves.
//!
//! Its own file because the two counters it prints come from different models
//! (the time base in periph/clocks.zig, the controller in periph/nvic.zig) and
//! the interesting part is the relation between them, which belongs to neither.
const clocks = @import("../../periph/clocks.zig");
const nvic = @import("../../periph/nvic.zig");
const tally_mod = @import("../../debug/tally.zig");
const elf = @import("../../core/elf.zig");
const symbols = @import("../../debug/symbols.zig");
const idle = @import("../../core/idle.zig");
const unmask = @import("../../core/unmask.zig");

const Writer = @import("report.zig").Writer;

/// A SysTick period is only worth anything to the firmware if something
/// raised for it. `collapsed` is how many wraps raised nothing, so a reader
/// can tell a slow run from a run whose clock is lying to it, and `rearms`
/// is the other side of the same ledger: stretches ended early to keep that
/// number down, each one a stretch whose cycles went uncharged.
pub fn timing(
    out: Writer,
    timebase: clocks.Clocks,
    seam: idle.Seam,
    interrupts: nvic.Nvic,
    release: unmask.Release,
) !void {
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
    if (seam.skipped != 0) {
        try out.print(
            "time: {d} of those cycles passed in a loop that could not change anything; {d} closure(s) over {d} boundary(ies)\n",
            .{ seam.skipped, seam.closures, seam.boundaries },
        );
    }
    try out.print(
        "interrupts: {d} taken, {d} returned, {d} held\n",
        .{ interrupts.taken, interrupts.returned, interrupts.held },
    );
    if (!release.quiet()) {
        try out.print(
            "interrupts: {d} waited out a mask over {d} instruction(s), {d} still masked, {d} abandoned\n",
            .{ release.lifted, release.stepped, release.stuck, release.faulted },
        );
    }
}

/// Where the machine was when each exception was taken.
///
/// A count of entries says the vectors fired; it cannot say whether one of
/// them cut a sequence that had to run whole. Naming the interrupted
/// function is what makes that answerable: an exception taken inside
/// `_tx_thread_sleep` or `_tx_thread_system_suspend` lands between the
/// increment of `_tx_thread_preempt_disable` and its matching decrement,
/// and a thread stopped in there holds the scheduler shut.
pub fn takenFrom(out: anytype, image: elf.Image, counted: tally_mod.Tally) !void {
    if (counted.quiet()) return;
    var room: [tally_mod.limits.kept]tally_mod.Site = undefined;
    const ranked = counted.ranked(&room);
    var listed: usize = 0;
    for (ranked) |site| {
        if (listed >= tally_mod.limits.listed) break;
        listed += 1;
        try out.print(
            "interrupts: {d} entry(ies) of exception {d} from pc 0x{X:0>8}",
            .{ site.writes, site.value, site.pc },
        );
        if (symbols.inside(image, site.pc)) |at| {
            try out.print(" {s}+0x{X}", .{ at.name, at.offset });
        }
        try out.print("\n", .{});
    }
    if (counted.displaced > 0) {
        try out.print(
            "interrupts: and {d} entry(ies) from places that did not stay in the tally\n",
            .{counted.displaced},
        );
    }
}
