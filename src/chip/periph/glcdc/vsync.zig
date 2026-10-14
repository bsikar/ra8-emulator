//! The panel's frame boundary on the board's virtual time base (RA8EMU-573).
//!
//! The GLCDC model composites a frame only when something calls `scanOut`,
//! and without a viewer the only caller is the end-of-run report. A viewer
//! that wants every frame a run shows (--frames-out) installs a Vsync on the
//! output stage; the board boundary hands it the time after each chunk, and
//! once a frame period has gone by the viewer's sink scans the panel.
//!
//! OPT-IN, on purpose: an in-run scan raises VPOS at the frame cadence, which
//! moves when a driver polling it sees a frame land. With no viewer installed
//! nothing here runs, the GLCDC still scans only for the report, and every
//! corpus row stays byte identical.
//!
//! DECISION: a fixed 60 Hz period. PANELCLK's divider is modelled
//! (sys.zig) but not the clock it divides, so a period derived from the
//! TCON totals would rest on a guessed source rate. A chunk that covers
//! several periods yields one scan, and the periods it swallowed are counted.
const std = @import("std");

pub const default_period_ns: u64 = 16_666_667;

/// Who scans when a frame boundary passes. The sink does the scan itself, so
/// it can size its capture buffer to the panel as the firmware has it now.
pub const Sink = struct {
    context: *anyopaque,
    frame: *const fn (context: *anyopaque, when_ns: u64) void,
    /// Polled after every chunk, frame boundary or not, for a viewer that
    /// waits on the picture holding still (the e-ink LUT status).
    settle: ?*const fn (context: *anyopaque, now_ns: u64) anyerror!void = null,
};

/// The panel's frame clock as the run's configuration asks for it
/// (RA8EMU R9): the first edge at `phase_ns`, one each `period_ns`. Root
/// config, applied identically to a plain run, a session and a restored
/// session; consumers attach to an armed clock and never arm or resize it.
pub const Config = struct {
    phase_ns: u64,
    period_ns: u64,
};

pub const Vsync = struct {
    /// Who is told when an edge passes, or nobody. The boundary runs the
    /// block's cheap frame event first and then notifies the sink; a sink
    /// present or absent never changes when the edges come.
    sink: ?Sink = null,
    period_ns: u64 = default_period_ns,
    next_ns: u64 = default_period_ns,
    /// Frame periods that ended.
    boundaries: u64 = 0,
    /// Of those, the ones that ended inside a chunk another one also ended
    /// in: frames the panel showed and the viewer never saw.
    swallowed: u64 = 0,

    /// True once at least one period ended at or before `now_ns`; the next
    /// boundary moves past `now_ns`.
    pub fn due(self: *Vsync, now_ns: u64) bool {
        if (now_ns < self.next_ns) return false;
        const ended = (now_ns - self.next_ns) / self.period_ns + 1;
        self.next_ns += ended * self.period_ns;
        self.boundaries += ended;
        self.swallowed += ended - 1;
        return true;
    }

    /// The sink's settle poll, when it has one.
    pub fn settle(self: *Vsync, now_ns: u64) !void {
        if (self.sink) |sink| if (sink.settle) |poll| try poll(sink.context, now_ns);
    }

    /// Advance the clock past `now_ns`. True when at least one frame edge
    /// passed: the caller runs the block's cheap frame event and then
    /// notifies the sink, in that order.
    pub fn tick(self: *Vsync, now_ns: u64) bool {
        return self.due(now_ns);
    }

    /// Tell the sink an edge passed, after the frame event has run.
    pub fn notify(self: *Vsync, now_ns: u64) void {
        if (self.sink) |sink| sink.frame(sink.context, now_ns);
    }
};

/// Pointer-free guest timing; a restore keeps the target sink and configuration.
pub const Saved = struct {
    period_ns: u64,
    next_ns: u64,
    boundaries: u64,
    swallowed: u64,

    pub fn of(live: Vsync) Saved {
        return .{ .period_ns = live.period_ns, .next_ns = live.next_ns, .boundaries = live.boundaries, .swallowed = live.swallowed };
    }

    pub fn install(self: Saved, live: *Vsync) error{BadValue}!void {
        if (self.period_ns == 0 or self.period_ns != live.period_ns or self.next_ns > std.math.maxInt(u64) - self.period_ns or self.boundaries > self.next_ns / self.period_ns or self.swallowed > self.boundaries or (self.boundaries != 0 and self.swallowed == self.boundaries)) return error.BadValue;
        live.next_ns = self.next_ns;
        live.boundaries = self.boundaries;
        live.swallowed = self.swallowed;
    }
};
