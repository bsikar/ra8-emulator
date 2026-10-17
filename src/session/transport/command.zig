//! The transport's command language: what a front end may ask the engine to
//! do, and what the transport reports back (time-travel design section 3).
//!
//! A command is queued, never run: `Transport.command` validates it and
//! returns a ticket, and `pump` drives the engine in bounded slices. The
//! newest command preempts the running job the way a Cancel would. A play's
//! speed paces scheduling only and never touches guest state.

const api = @import("../api.zig");
const scheduler = @import("ra8_chip").core.scheduler;

pub const Error = error{ InvalidSpeed, InvalidArgs, NotReady, Cancelled };

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
};

pub const Cont = struct {};

pub const Advance = struct {
    core: api.Core,
    /// Virtual nanoseconds to move the board's time forward by.
    ns: u64,
};

pub const Seek = struct {
    /// v1 transport accepts the type; execution waits for the history
    /// contracts (units 17/18) and is refused with NotReady until then.
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
    advance: Advance,
    seek: Seek,
    run_to: RunTo,
};

/// One accepted command. Monotonic per transport.
pub const Ticket = u64;

/// What the engine was doing when reported (section 3's transport states).
/// An advance is its own phase: it runs until a virtual time, not a stop.
pub const Phase = enum { halted, playing, continuing, advancing, stepping };

/// How far a job has gone, in the units the job itself carries.
pub const Progress = struct {
    /// The job's virtual-time target, when it has one (an advance).
    target_ns: ?u64 = null,
    /// The virtual time reached so far, when it has a target.
    reached_ns: ?u64 = null,
    /// Slices the job has driven so far.
    slices: u64 = 0,
};

pub const Report = struct {
    epoch: u64,
    phase: Phase,
    /// The live scheduler position, when the run has a boundary grid.
    position: ?scheduler.Position,
    progress: Progress,
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
