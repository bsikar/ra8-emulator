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
const pend_sites = @import("../../core/pend_sites.zig");
const pc_hits = @import("../../debug/pc_hits.zig");

const Writer = @import("report.zig").Writer;

/// Everything a run can say about pends the firmware wrote by hand.
///
/// Its own function rather than more lines inside `timing`, which the
/// length gate was right to stop: this is one subject (what the firmware
/// asked of the controller and what became of it) and the rest of `timing`
/// is another (cycles, periods, the idle seam).
fn pends(out: Writer, pending: pend_break.Pend) !void {
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
        if (pending.swallowed_placed) try out.print(
            "time: the first of them stored at pc 0x{X:0>8}, {d} of the rest stored somewhere else\n",
            .{ pending.swallowed_at, pending.swallowed_elsewhere },
        );
        if (pending.looks != 0) try out.print(
            "time: {d} of them ended the stretch so the pend could be looked at again\n",
            .{pending.looks},
        );
    }
    if (pending.reentered != 0) {
        try out.print(
            "time: {d} stretch(es) opened on the very store that ended the one before, first at pc 0x{X:0>8}\n",
            .{ pending.reentered, pending.reentered_at },
        );
    }
    if (pending.reopened != 0) {
        try out.print(
            "time: {d} stretch(es) opened PAST the store that ended them, first at pc 0x{X:0>8} after a stop read as 0x{X:0>8}\n",
            .{ pending.reopened, pending.reopened_at, pending.reopened_from },
        );
    }
    if (pending.stops != pending.reentered + pending.reopened) {
        try out.print(
            "time: {d} stop(s) were asked for but only {d} reached a boundary, so {d} WERE OVERWRITTEN BEFORE THE STRETCH ENDED\n",
            .{
                pending.stops,
                pending.reentered + pending.reopened,
                pending.stops - (pending.reentered + pending.reopened),
            },
        );
    }
}

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
    try pends(out, pending);
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

/// Where the firmware stored a pend that was already standing.
///
/// The count of swallowed stores says the scheduler asked for a switch it
/// did not get; it cannot say whether one site asked a million times or a
/// million sites asked once, and the two want opposite fixes. Naming the
/// addresses answers it. On ThreadX there are two by construction,
/// `_tx_thread_system_suspend` and `_tx_thread_system_resume`, both
/// writing `ICSR.PENDSVSET` by hand at the end of their own bookkeeping.
pub fn pendStores(out: anytype, image: elf.Image, pending: pend_break.Pend) !void {
    // Ranked on a copy: the sort is the report's business and the run's
    // own table has no reason to come back reordered.
    var sites = pending.sites;
    if (sites.quiet()) return;
    for (sites.ranked()) |site| {
        try out.print(
            "time: {d} pend(s) landed on a standing one from pc 0x{X:0>8}",
            .{ site.count, site.pc },
        );
        if (symbols.inside(image, site.pc)) |at| {
            try out.print(" {s}+0x{X}", .{ at.name, at.offset });
        }
        try out.print("\n", .{});
    }
    if (sites.overflowed != 0) {
        try out.print(
            "time: and {d} more from addresses past the {d} the table keeps\n",
            .{ sites.overflowed, pend_sites.limits.sites },
        );
    }
}

/// How many times each counted instruction ran.
///
/// Every other counter in the report is a side effect of something else:
/// stores that landed in a word, stores that found a pend standing,
/// exceptions taken. When two of those disagree about the same stretch of
/// code there is nothing in the tree to settle it, because neither of them
/// measures the execution. This does, and nothing else, so a count here is
/// the one number that can call another one wrong.
pub fn pcHits(out: anytype, image: elf.Image, hits: pc_hits.Hits) !void {
    if (hits.quiet()) return;
    for (hits.asked()) |one| {
        try out.print("time: pc 0x{X:0>8}", .{one.at});
        if (symbols.inside(image, one.at)) |at| {
            try out.print(" {s}+0x{X}", .{ at.name, at.offset });
        }
        try out.print(" ran {d} time(s)\n", .{one.hits});
    }
    if (hits.refused != 0) {
        try out.print(
            "time: {d} more address(es) asked for than the {d} a run can count\n",
            .{ hits.refused, pc_hits.limits.places },
        );
    }
}
