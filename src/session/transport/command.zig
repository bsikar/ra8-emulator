//! The transport's command language: what a front end may ask the engine to
//! do, and what the transport reports back (time-travel design section 3).
//!
//! A command is queued, never run: `Transport.command` validates it and
//! returns a ticket, and `pump` drives the engine in bounded slices. The
//! newest command preempts the running job the way a Cancel would. A play's
//! speed paces scheduling only and never touches guest state.

const api = @import("../api.zig");
const scheduler = @import("ra8_chip").core.scheduler;

pub const Error = error{ InvalidSpeed, InvalidArgs, NotReady, Cancelled, HistoryBroken, WatchArmed };

/// Where a play or step moves. Backward play is refused until the history
/// contracts land (units 17/18); the type is here so front ends speak it.
pub const Direction = enum { fwd, back };

pub const Play = struct {
    dir: Direction = .fwd,
    /// Times real time; null is `max` (unpaced), like `--speed max`.
    speed: ?f64 = null,
};

pub const Step = struct {
    core: api.Core,
    count: u64 = 1,
    /// Where the step moves. Backward needs a bound history bridge (the
    /// step undoes one instruction through restore and replay) and stays
    /// refused without one.
    dir: Direction = .fwd,
};

pub const Cont = struct {};

pub const Advance = struct {
    core: api.Core,
    /// Virtual nanoseconds to move the board's time forward by.
    ns: u64,
};

pub const Seek = struct {
    /// The queue door validates the target text; with a history bridge
    /// bound (unit 17) the transport plans the seek from the committed
    /// log's facts and executes it, and without one it is NotReady.
    target: []const u8 = "",
};

pub const RunTo = struct {
    core: api.Core,
    address: u32,
};

pub const Command = union(enum) {
    play: Play,
    pause,
    step: Step,
    cont: Cont,
    /// Reverse-continue: a backward search over the recorded path for
    /// the latest breakpoint or fault behind the run, through restore
    /// and replay (design 2.4). Needs a bound history bridge and is
    /// refused while any watchpoint is armed (v1).
    rcont,
    advance: Advance,
    seek: Seek,
    run_to: RunTo,
};

/// One accepted command. Monotonic per transport.
pub const Ticket = u64;

/// What the engine was doing when reported (section 3's transport states).
/// An advance is its own phase: it runs until a virtual time, not a stop.
pub const Phase = enum { halted, playing, continuing, advancing, stepping, seeking, reverse_continuing };

/// How far a job has gone, in the units the job itself carries.
pub const Progress = struct {
    /// The job's virtual-time target, when it has one (an advance).
    target_ns: ?u64 = null,
    /// The virtual time reached so far, when it has a target.
    reached_ns: ?u64 = null,
    /// Slices the job has driven so far.
    slices: u64 = 0,
    /// A seek's resolved target position, once its plan is known. Time
    /// targets resolve against the virtual-time index first, so this stays
    /// null until the target names a position the run can hold.
    target_position: ?scheduler.Position = null,
    /// A seek's arrival estimate, in host nanoseconds at the live rate,
    /// once the replay distance is known.
    eta_ns: ?u64 = null,
};

pub const Report = struct {
    epoch: u64,
    phase: Phase,
    /// The running job's state with its payloads, or null when nothing
    /// runs. `phase` stays the bare tag; this is what a front end
    /// renders the state from.
    state: ?State = null,
    /// The live scheduler position, when the run has a boundary grid.
    position: ?scheduler.Position,
    progress: Progress,
};

/// What the running job is, with the payloads a front end renders from
/// it (section 2.1's transport states). The report's `phase` stays the
/// bare tag the wire already carries; this carries the rest of the
/// state's shape. It is null when nothing runs.
///
/// The payloads carry only what the job really holds: a step's kind
/// (instruction, over, finish) and a seek's post-landing `then` are not
/// modelled yet and arrive with their own contracts, so they are absent
/// here rather than faked.
pub const State = union(enum) {
    playing: struct {
        dir: Direction,
        /// Times real time; null is `max` (unpaced).
        speed: ?f64,
    },
    continuing: struct { dir: Direction },
    advancing: struct {
        /// The virtual time the advance runs until.
        target_ns: u64,
    },
    stepping: struct {
        core: api.Core,
        /// Steps still to run.
        count: u64,
        /// Where the step moves, the command's own direction.
        dir: Direction,
    },
    seeking: struct {
        /// The seek's landing position, phase included.
        target: scheduler.Position,
    },
    reverse_continuing: struct {
        /// The core the search runs on.
        core: api.Core,
    },
};

/// A job that ended during a pump, with the ticket that queued it.
pub const Finished = struct {
    ticket: Ticket,
    epoch: u64,
    core: api.Core,
    ended: api.Ended,
};

/// What one bounded pump did.
pub const Pumped = struct {
    report: Report,
    /// The job that ended inside this pump, when one did.
    finished: ?Finished = null,
    /// Any subscriber queue is half full: drain before pumping again.
    drain: bool = false,
};

/// A host wall clock the transport reads, never sleeps against. Injected so
/// a test drives it and a front end owns its own.
pub const Wall = struct {
    context: *anyopaque,
    nowFn: *const fn (*anyopaque) u64,
};

/// Whether the application wants the blocking `finish` to come back now.
pub const Poll = struct {
    context: *anyopaque,
    pollFn: *const fn (*anyopaque) bool,
};
