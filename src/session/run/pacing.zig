//! The pacer as the board holds it (RA8EMU-181, slice 2).
//!
//! The run loop belongs to the dual-core lane, so pacing hangs off the board's
//! chunk boundary instead (src/board/boundary.zig), which every stretch of a
//! run already passes through with virtual time freshly advanced. Nothing is
//! attached by default, so an unpaced run does exactly what it did before.
//!
//! A boundary comes every few tens of microseconds of virtual time. Asking the
//! host to sleep that often would cost more than the sleeps, so the pacer is
//! only consulted once at least `step_ns` of virtual time has gone by: at 1x
//! that is at most a thousand checks a second, and a 10 ms timer still lands
//! within a millisecond of the wall clock.
const std = @import("std");
const pacer = @import("pacer.zig");

/// The least virtual time between two looks at the wall clock.
pub const step_ns: u64 = std.time.ns_per_ms;

pub const Pacing = struct {
    pacer: pacer.Pacer = .{},
    /// The clock a caller injected (a test's fake); read only when `host` is null.
    clock: pacer.Clock = undefined,
    /// The host clock a `--realtime` run paces against, owned by the Pacing
    /// so each run carries its own anchor (RA8EMU-181). Null for injected
    /// clocks.
    host: ?pacer.HostClock = null,
    /// Virtual time the pacer was last consulted at.
    last_ns: u64,

    /// The clock this Pacing reads: the owned host clock when it has one,
    /// else the injected one.
    fn clockOf(self: *Pacing) pacer.Clock {
        if (self.host) |*held| return held.clock();
        return self.clock;
    }

    /// Pace from `now_ns` on at `speed_milli` (1000 is real time) against a
    /// caller-supplied clock.
    pub fn start(clock: pacer.Clock, now_ns: u64, speed_milli: u64) Pacing {
        return .{
            .pacer = pacer.Pacer.begin(clock, now_ns, speed_milli),
            .clock = clock,
            .last_ns = now_ns,
        };
    }

    /// Called at every chunk boundary with the board's virtual time.
    pub fn after(self: *Pacing, now_ns: u64) void {
        if (now_ns -| self.last_ns < step_ns) return;
        self.last_ns = now_ns;
        self.pacer.pace(self.clockOf(), now_ns);
    }

    pub fn setSpeed(self: *Pacing, now_ns: u64, speed_milli: u64) void {
        self.last_ns = now_ns;
        self.pacer.setSpeed(self.clockOf(), now_ns, speed_milli);
    }

    pub fn report(self: *Pacing, now_ns: u64) pacer.Report {
        return self.pacer.report(self.clockOf(), now_ns);
    }
};

/// Pace a run against the host's monotonic clock from virtual time `now_ns`.
/// The run owns its clock: it lives inside the Pacing and every read
/// resolves through the Pacing it lands in, so a later machine starts its
/// own anchor instead of sharing this process's (RA8EMU-181).
pub fn attachHost(paced: *?Pacing, now_ns: u64, io: std.Io, speed_milli: u64) void {
    paced.* = Pacing{ .host = pacer.HostClock.init(io), .last_ns = now_ns };
    paced.*.?.pacer = pacer.Pacer.begin(paced.*.?.clockOf(), now_ns, speed_milli);
}

/// The end-of-run line, only when the run was paced, so an unpaced run's
/// report is unchanged.
pub fn line(out: anytype, paced: ?Pacing, now_ns: u64) !void {
    var running = paced orelse return;
    try write(out, running.report(now_ns));
}

pub fn write(out: anytype, r: pacer.Report) !void {
    try out.print("pace: requested {d}.{d:0>3}x, achieved {d}.{d:0>3}x, drift {d}.{d:0>3} ms, {d} slips\n", .{
        r.requested_milli / 1000,
        r.requested_milli % 1000,
        r.achieved_milli / 1000,
        r.achieved_milli % 1000,
        r.drift_ns / std.time.ns_per_ms,
        (r.drift_ns % std.time.ns_per_ms) / std.time.ns_per_us,
        r.slips,
    });
}
