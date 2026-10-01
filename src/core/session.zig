//! What runs alongside the core for the length of one run.
//!
//! A run is not just a core and a budget. Modelled time has to be charged,
//! a controller has to get its turn at each boundary, the board's blocks
//! have to tick, and a handful of watches (a counter, a breakpoint, a
//! deadline) have to be given the chance to end it. All of that is optional
//! and none of it belongs to the core, so it is gathered here and handed to
//! `Engine.run` as one value rather than a growing argument list.
//!
//! Everything is off by default: a bare `.{}` is one uninterrupted stretch
//! of execution with no modelled time and no exceptions, which is what the
//! loader and the smaller tests want. Every field is a pointer rather than
//! a copy, so the caller still owns the thing and can ask it afterwards
//! what happened during the run.
const clocks = @import("../periph/clocks.zig");
const nvic = @import("../periph/nvic.zig");
const mpu_guard = @import("mpu_guard.zig");
const reboot = @import("reboot.zig");
const breakpoint = @import("../debug/breakpoint.zig");
const stop = @import("stop.zig");
const undefined_ops = @import("undefined_ops.zig");
const deadline = @import("deadline.zig");
const fault = @import("fault.zig");
const idle = @import("idle.zig");
const unmask = @import("unmask.zig");
const pend_break = @import("pend_break.zig");
const pend_pace = @import("pend_pace.zig");
const hotspots = @import("../debug/hotspots.zig");
const tally = @import("../debug/tally.zig");
const taken_in = @import("../debug/taken_in.zig");
const functions = @import("../debug/functions.zig");

/// Records the invalid access behind a fault.
pub const Watch = fault.Watch;

/// The board's chunk-boundary hook.
pub const Tick = @import("tick.zig").Tick;

pub const Session = struct {
    /// Records the invalid access behind a fault.
    watch: ?*Watch = null,
    /// Charged one chunk of time per chunk of execution.
    timebase: ?*clocks.Clocks = null,

    /// An explicit boundary width, from `--chunk`, overriding the time
    /// base's own. Null leaves the cadence where it was. This exists to
    /// test whether a result depends on where the boundaries fall, so it
    /// deliberately outranks the clock: see cadence.configuredFrom.
    per_boundary: ?u32 = null,
    /// Consulted at each chunk boundary for an exception to take.
    interrupts: ?*nvic.Nvic = null,
    /// Run at each chunk boundary, before the controller picks: the
    /// peripheral side of a tick, where a block that has something to raise
    /// raises it. The board hands one in; the engine only calls it.
    board: ?Tick = null,
    /// Where a reset request the board took at the boundary is left for the
    /// engine to perform. A reset resets the core, and the core is the
    /// engine's, so the board asks and this loop does it.
    reboot: ?*reboot.Reboot = null,
    /// A counter in RAM to watch, and the floor that ends the run once it
    /// gets there. Null watches nothing. A pointer rather than a copy so
    /// the caller can ask afterwards whether the stop was what ended it.
    stop: ?*stop.Stop = null,
    /// An instruction address to stop at the first time execution reaches
    /// it. Null runs to the budget. Handed to the emulator as the point to
    /// run until, so it costs nothing per instruction; a pointer rather
    /// than a copy so the caller can ask afterwards whether it arrived.
    brk: ?*breakpoint.Break = null,
    /// MPU enforcement: the traps over the read-only regions, and the store
    /// one of them caught. Null runs with the table captured but nothing
    /// checked against it, which is every test that does not program one.
    protection: ?*mpu_guard.Guard = null,
    /// Modelled time the run is allowed, counted in the SysTick periods the
    /// time base reports. Null is untimed. Needs `timebase` to have anything
    /// to count, so an image with no clocks attached is never cut short by
    /// a deadline it could not have reached.
    deadline: ?*deadline.Deadline = null,
    /// Proves a stretch of execution cannot change anything, so it can be
    /// charged to the clocks without being run. Null executes every
    /// instruction, which is what every test that is not about the seam
    /// wants. src/core/idle.zig says what has to hold before one is
    /// skipped.
    idle: ?*idle.Seam = null,
    /// Lets a pend that is ready but masked wait out the mask instead of
    /// being dropped for a whole period. Null keeps the old behaviour, which
    /// is what every test that is not about delivery timing wants.
    /// src/core/unmask.zig says what it costs and what bounds it.
    unmask: ?*unmask.Release = null,
    /// Where the run spent itself: the program counter sampled once per
    /// chunk boundary. Null samples nothing, which is what every test that
    /// is not about the sampler wants. src/debug/hotspots.zig says what one
    /// sample per boundary can and cannot answer.
    pcs: ?*hotspots.Table = null,
    /// Where the run went, by function. Coarser than `pcs` and the one
    /// that survives a run touching thousands of addresses.
    fns: ?*functions.Table = null,

    /// Where the machine was when an exception was taken, tallied as the
    /// pair (interrupted program counter, exception number).
    ///
    /// A count of entries says how busy the vectors are; it cannot say
    /// whether a switch cut a sequence that had to run whole. ThreadX puts
    /// a window like that in every sleep: `_tx_thread_sleep` increments
    /// `_tx_thread_preempt_disable`, restores PRIMASK, and only then calls
    /// `_tx_thread_system_suspend`, which decrements it again. A thread
    /// stopped in there holds the flag up, and the timer handler refuses
    /// to issue a PendSV while it is up. This is how to ask how often an
    /// exception lands between the two.
    taken_from: ?*tally.Tally = null,

    /// Every exception taken inside one named function, kept whole. The
    /// tally above displaces its rarest row, which is exactly the entry a
    /// once-per-run fault is. src/debug/taken_in.zig carries the rest.
    taken_in: ?*taken_in.Window = null,
    /// The swept undefined sites, when reaching one should end the run.
    /// Null runs past them and only counts, which is the default: the
    /// sweep reports, it does not decide.
    undefined_sites: ?*undefined_ops.Found = null,
    /// A pend the firmware wrote inside a stretch, which ends that
    /// stretch so the controller can take it straight away. Null leaves a
    /// hand-written pend waiting for the next boundary, which is what
    /// every test that is not about delivery timing wants.
    /// src/core/pend_break.zig says what it costs.
    pend: ?*pend_break.Pend = null,
    /// Shortens the next stretch while a pend the firmware wrote is still
    /// standing unserved, so the controller's next look is a couple of
    /// thousand instructions away rather than a whole chunk. Null keeps
    /// the full boundary, which is what every test that is not about
    /// delivery timing wants. src/core/pend_pace.zig says why this is the
    /// side of the seam worth shortening.
    pend_pace: ?*pend_pace.Pace = null,
};
