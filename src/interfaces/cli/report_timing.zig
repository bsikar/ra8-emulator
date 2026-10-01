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
const taken_in_mod = @import("../../debug/taken_in.zig");
const elf = @import("../../core/elf.zig");
const symbols = @import("../../debug/symbols.zig");
const idle = @import("../../core/idle.zig");
const unmask = @import("../../core/unmask.zig");
const pend_break = @import("../../core/pend_break.zig");

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
    pending: pend_break.Pend,
) !void {
    if (pending.cuts != 0) {
        try out.print(
            "time: {d} boundary(ies) ended where the firmware pended an exception\n",
            .{pending.cuts},
        );
    }
    if (pending.swallowed != 0) {
        try out.print(
            "time: {d} more pend(s) landed on one already standing and raised nothing, {d} of them inside a handler\n",
            .{ pending.swallowed, pending.swallowed_in_handler },
        );
        try out.print(
            "time: {d} of them landed inside one stretch at worst, over {d} stretch(es)\n",
            .{ pending.longest_stretch, pending.stretches },
        );
        if (pending.looks != 0) try out.print(
            "time: {d} of them ended the stretch so the pend could be looked at again\n",
            .{pending.looks},
        );
    }
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
    try controller(out, interrupts);
    if (!release.quiet()) {
        try out.print(
            "interrupts: {d} waited out a mask over {d} instruction(s), {d} still masked, {d} abandoned\n",
            .{ release.lifted, release.stepped, release.stuck, release.faulted },
        );
    }
}

/// What the controller did with the pends it was offered: the headline, then
/// the three ways a pend can fail to run. Held is the pick's winner being
/// refused (src/periph/held.zig); passed is a pend that never got that far
/// because something more urgent was pending too (src/periph/passed.zig).
fn controller(out: Writer, interrupts: nvic.Nvic) !void {
    try out.print(
        "interrupts: {d} taken, {d} returned, {d} held\n",
        .{ interrupts.taken, interrupts.returned, interrupts.held },
    );
    if (interrupts.chained != 0) try out.print(
        "interrupts: {d} return(s) went straight into another handler\n",
        .{interrupts.chained},
    );
    if (!interrupts.why.quiet()) try out.print(
        "interrupts: held {d} masked, {d} outranked, {d} too deep, {d} with no vector\n",
        .{
            interrupts.why.masked,
            interrupts.why.outranked,
            interrupts.why.deep,
            interrupts.why.no_vector,
        },
    );
    if (interrupts.why.waiting != 0) try out.print(
        "interrupts: exception {d} first waited on exception {d}\n",
        .{ interrupts.why.waiting, interrupts.why.winner },
    );
    if (interrupts.passed.quiet()) return;
    try out.print(
        "interrupts: {d} pend(s) lost the pick, exception {d} first lost to exception {d}\n",
        .{ interrupts.passed.losses, interrupts.passed.loser, interrupts.passed.winner },
    );
    try out.print(
        "interrupts: exception {d} lost {d} boundary(ies) in a row at its worst\n",
        .{ interrupts.passed.starved, interrupts.passed.longest },
    );
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

/// Every exception taken inside the function `--taken-in` named.
///
/// Printed whole, oldest first, with nothing dropped in the middle: this
/// exists for the entry that happens once in a run, which is the one a
/// tally cannot hold. A window that caught nothing says so, because "no
/// exception was taken in there" is an answer and usually the surprising
/// one.
pub fn takenIn(out: anytype, image: elf.Image, spec: ?[]const u8, window: ?taken_in_mod.Window) !void {
    const asked = spec orelse return;
    const one = window orelse return;
    try out.print(
        "taken-in: {s} @0x{X:0>8}+0x{X}, {d} exception(s) taken inside\n",
        .{ asked, one.base, one.size, one.seen },
    );
    for (one.kept()) |entry| {
        try out.print(
            "                  #{d} exception {d} at pc 0x{X:0>8}",
            .{ entry.at, entry.number, entry.pc },
        );
        if (symbols.inside(image, entry.pc)) |at| {
            try out.print(" {s}+0x{X}", .{ at.name, at.offset });
        }
        try out.print("\n", .{});
    }
    if (one.missed() > 0) {
        try out.print("                  and {d} more not kept\n", .{one.missed()});
    }
}
