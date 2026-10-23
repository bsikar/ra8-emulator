//! The shell's run (RA8EMU-1118): Run keeps a core going in slices, so the
//! window's thread never waits on a run it cannot stop. While Run is lit,
//! every window frame owes the board one frame of its own time at the speed
//! asked for, and `max` owes as much as fits. The frame pays in `advance`
//! requests (RA8EMU-654) of at most one unit each, and the next goes out
//! only once the last has answered, so a pause, a click or a redraw is never
//! further away than one slice. Board time a frame could not pay is dropped,
//! not carried to the next frame: a host that cannot keep up falls behind,
//! and the clock readout says by how much.
//!
//! A unit starts short and doubles while slices come back well inside the
//! frame's share of wall time, up to one frame of board time. A slice that
//! overruns the share shrinks it in proportion, which keeps the window at
//! its frame rate on a host too slow for the speed asked for.
//!
//! A unit of board time costs about a thousand times more wall time when
//! the core is busy than when it sleeps, and the shell cannot tell which is
//! coming. So an overrun is remembered (RA8EMU-1127): the unit may grow back
//! only to a ceiling of four times what fitted, and the ceiling eases up one
//! doubling at a time while nothing overruns. An image that sleeps and then
//! turns busy again holds the window for a few frames, not for the cost of
//! a whole frame of busy board time.
//!
//! Every slice ends in a `count` stop. That is the slice's end and not the
//! run's, so `observe` names its stop event a boundary and nothing else
//! takes it for a stop. A pause is settled here: `halted` hands back where
//! the last slice left the core. A stop for any other reason ends the run,
//! and its stop event goes on to the status bar and the leaves.
//!
//! The sizing assumes a session that answers inside the frame, as the one
//! served on the window's thread does. A session on a thread of its own
//! (session_worker.zig) takes nothing from the frame: its slices go out all
//! through the frame, each as the last one answers, and are sized by how
//! long the session took over them (`answered_at`), so a pause is still about
//! one share away.
//!
//! On a transport-capable link (RA8EMU-1196) the slices go out as
//! `advance_async`, the queue confirmation leaves the slice out, and the
//! transport topic's completion is both the answer and the boundary, so the
//! run never waits on the session's turn and a pause preempts the job in
//! flight.
const std = @import("std");
const proto = @import("ra8_rpc").session.rpc;
const session_link = @import("../session_link.zig");
const speed_field = @import("../speed_field.zig");
const run_turbo = @import("run_turbo.zig");

const Link = session_link.Link;
const Arrival = session_link.Arrival;

/// One window frame: the board time a frame owes at 1x, and the longest unit.
pub const frame_ns: u64 = std.time.ns_per_s / 60;
/// The share of a frame's wall time its slices may take; the rest draws.
pub const share_ns: u64 = frame_ns * 3 / 4;
/// The unit a run starts from: short, because nothing is known yet about
/// what the image costs, and it doubles within a frame when that is little.
pub const first_unit_ns: u64 = 20 * std.time.ns_per_us;
/// The shortest unit a slow host is cut down to.
pub const least_unit_ns: u64 = 2 * std.time.ns_per_us;
/// How far over what fitted the unit may grow back after an overrun: the
/// next surprise then holds the window for about this many shares.
pub const ceiling_factor: u64 = 4;
/// Frames with no overrun before the ceiling doubles: ten seconds.
pub const ease_frames: u32 = 600;
/// The most slices one frame sends whatever the clock says, so a clock that
/// stands still cannot hold the frame.
pub const max_slices: u32 = 1024;

/// What `observe` made of an arrival.
pub const Seen = enum {
    /// Not the run's.
    other,
    /// The answer to the slice in flight.
    slice,
    /// The stop event that ends a slice: the run goes on, so nothing stopped.
    boundary,
};

pub const Run = struct {
    core: proto.Core = .cpu0,
    /// Run is lit: frames keep paying slices until a pause or a stop.
    lit: bool = false,
    /// The advance in flight, the board time it asked for and when it left.
    slice_id: ?u32 = null,
    asked_ns: u64 = 0,
    sent_ns: u64 = 0,
    /// Board time this frame still owes; null owes whatever fits (`max`).
    owed_ns: ?u64 = 0,
    /// The wall time this frame's slices stop by, and how many it has sent.
    until_ns: u64 = 0,
    sent: u32 = 0,
    unit_ns: u64 = first_unit_ns,
    /// The board time one frame owes at 1x: one sixtieth of a second, or
    /// what the frame before really took when the window is paced by its
    /// display (shell/pace.zig).
    period_ns: u64 = frame_ns,
    /// The longest the unit may grow to. An overrun pulls it down, and it
    /// eases back to one frame while nothing overruns.
    ceiling_ns: u64 = frame_ns,
    /// Frames left before the ceiling may double.
    ease: u32 = 0,
    /// Where the last slice left the core, or where Run found it.
    address: u32 = 0,
    /// Board time when the last slice ended.
    board_ns: ?u64 = null,
    /// The last slice's stop event is still to come.
    boundary_due: bool = false,
    /// A pause landed: where the core halted, until `halted` takes it.
    settled: ?u32 = null,
    /// The session refused the last slice.
    refused: bool = false,
    /// The slice path the link's caps picked (RA8EMU-1196): on a
    /// transport-capable link the slice goes out as `advance_async`, its
    /// queue confirmation leaves it out, and the completion arrives on the
    /// transport topic; on a plain link it answers on the wire as before.
    slice_async: bool = false,
    /// The transport topic subscription for the async path is out. The
    /// served context keeps subscriptions, so one send covers the link's
    /// life.
    subscribed: bool = false,
    /// A turbo run's queued advance (slice 19): its ask id while the
    /// queue confirmation is out, then whether the job is on the
    /// transport. A refused queue marks `turbo_refused`; a landed job
    /// marks `turbo_arrived`, handed out once for the clock re-read.
    turbo_id: ?u32 = null,
    turbo_out: bool = false,
    turbo_refused: bool = false,
    turbo_arrived: bool = false,
    /// The queued turbo's aim and live-rate estimate (slice 19): the
    /// confirmation supplies the ends, each progress event re-derives the
    /// remaining wall time from the rate so far, and the completion
    /// clears it.
    turbo_target_ns: u64 = 0,
    turbo_from_ns: u64 = 0,
    turbo_started_wall_ns: u64 = 0,
    turbo_eta: ?u64 = null,
    /// When the session last put an answer on the wire, on the shell's
    /// clock, for a session on a thread of its own; null is one that answers
    /// on the window's thread, timed by the frame.
    answered_at: ?*const std.atomic.Value(u64) = null,

    /// Light Run on a core halted at `address`.
    pub fn start(self: *Run, address: u32) void {
        if (self.lit) return;
        self.lit = true;
        self.refused = false;
        self.address = address;
        self.unit_ns = first_unit_ns;
        self.owed_ns = 0;
    }

    /// No further slice goes out. With none in flight the core is already
    /// halted where the last one left it. With a queued async slice the
    /// pause command preempts the job (RA8EMU-1196) and its completion
    /// hands the halt back; a sync slice answers within the frame and
    /// settles through the answer as before. The link is null where no
    /// session is in reach of the caller (a bare-state test).
    pub fn pause(self: *Run, link: ?*Link) void {
        if (!self.lit) return;
        self.lit = false;
        if (self.slice_id == null or !self.slice_async) {
            if (self.slice_id == null) self.settled = self.address;
            return;
        }
        _ = link.?.send(proto.CoreOnly, .pause, .{ .core = self.core }) catch return;
    }

    /// The image under the run was replaced (RA8EMU-959): no further slice
    /// goes out, and there is no halt of the old image to hand out.
    pub fn replaced(self: *Run) void {
        self.lit = false;
        self.settled = null;
        self.refused = false;
    }

    /// Where a pause, or a refused slice, left the core; handed out once.
    pub fn halted(self: *Run) ?u32 {
        const at = self.settled orelse return null;
        self.settled = null;
        return at;
    }

    /// Whether a turbo run's completion still wants the clock read again
    /// (slice 19); handed out once.
    pub fn takeTurboArrival(self: *Run) bool {
        if (!self.turbo_arrived) return false;
        self.turbo_arrived = false;
        return true;
    }

    /// A new window frame at wall time `now_ns`. It owes one frame of board
    /// time at `milli` thousandths of real time, and nothing from before.
    pub fn frame(self: *Run, now_ns: u64, milli: u64) void {
        self.owed_ns = if (milli == speed_field.max_wire) null else @intCast(@as(u128, self.period_ns) * milli / speed_field.real_time);
        self.until_ns = if (self.answered_at == null) now_ns +| share_ns else std.math.maxInt(u64);
        self.sent = 0;
        if (self.ease != 0) {
            self.ease -= 1;
        } else if (self.ceiling_ns < frame_ns) {
            self.ceiling_ns = @min(frame_ns, self.ceiling_ns * 2);
            self.ease = ease_frames;
        }
    }

    /// Start a turbo run (slice 19): queue an unpaced advance on the
    /// transport that runs the board forward `ns` of virtual time and
    /// completes on the transport topic, the way the spec's unrun tail
    /// asks for. Only from a halted run: a lit run's slices and the
    /// turbo's job would fight for the core. Needs a transport-capable
    /// link: the job, its preemption and its records are the
    /// transport's, and a plain link has no queue to hold a long one.
    pub fn turbo(self: *Run, link: *Link, ns: u64) !void {
        return run_turbo.turbo(self, link, ns);
    }

    /// Send the frame's next slice. False when Run is not lit, a slice is
    /// still out, the frame has paid what it owes or spent its share, or
    /// the link's pending table is full: other leaves' reads hold the slice
    /// back until their answers free a slot, and the run goes on. A
    /// transport-capable link (bit 15) sends `advance_async` and completes
    /// on the transport topic; a plain link sends `advance`.
    pub fn next(self: *Run, link: *Link, now_ns: u64) bool {
        if (!self.lit or self.slice_id != null) return false;
        if (now_ns >= self.until_ns or self.sent == max_slices) return false;
        const want = if (self.owed_ns) |owed| @min(owed, self.unit_ns) else self.unit_ns;
        if (want == 0) return false;
        self.slice_id = self.sendSlice(link, want) catch |err| {
            if (err != error.TableFull) self.refuse();
            return false;
        };
        self.asked_ns = want;
        self.sent_ns = now_ns;
        self.sent += 1;
        return true;
    }

    /// Send one slice. On a transport-capable link (bit 15) the transport
    /// topic is subscribed first and the slice goes out as `advance_async`
    /// (RA8EMU-1196); on a plain link it answers on the wire as `advance`.
    fn sendSlice(self: *Run, link: *Link, want: u64) !u32 {
        const async_path = link.caps() & proto.transport_cap != 0;
        if (async_path and !self.subscribed) {
            _ = try link.send(proto.Subscription, .subscribe, .{ .core = self.core, .topic = .transport });
            self.subscribed = true;
        }
        self.slice_async = async_path;
        if (async_path) return link.send(proto.Advance, .advance_async, .{ .core = self.core, .ns = want });
        return link.send(proto.Advance, .advance, .{ .core = self.core, .ns = want });
    }

    /// Take an arrival at wall time `now_ns`.
    pub fn observe(self: *Run, arrival: Arrival, now_ns: u64) Seen {
        switch (arrival) {
            .response => |response| return self.observeResponse(response, now_ns),
            .event => |event| return self.observeEvent(event, now_ns),
        }
    }

    fn observeResponse(self: *Run, response: anytype, now_ns: u64) Seen {
        if (run_turbo.observeResponse(self, response, now_ns)) |seen| return seen;
        if (self.slice_id == null or response.id != self.slice_id.?) return .other;
        if (self.slice_async) {
            // The queue confirmation (RA8EMU-1196): the slice stays
            // out and completes on the transport topic.
            const queued: ?proto.AdvanceQueued = switch (response.result) {
                .ok => |bytes| proto.decode(proto.AdvanceQueued, bytes) catch null,
                .err => null,
            };
            if (queued == null) {
                self.slice_id = null;
                self.refuse();
                return .slice;
            }
            return .other;
        }
        self.slice_id = null;
        self.answered(response.result, now_ns);
        return .slice;
    }

    fn observeEvent(self: *Run, event: anytype, now_ns: u64) Seen {
        if (event.topic == @backingInt(proto.Topic.transport)) {
            const done = proto.decode(proto.TransportEvent, event.payload) catch return .other;
            if (run_turbo.observeTransport(self, done, now_ns)) |seen| return seen;
            if (!self.slice_async or self.slice_id == null) return .other;
            if (done.finished != 1) return .other;
            self.slice_id = null;
            self.arrived(done.to_ns -| done.from_ns, done.to_ns, done.address, done.reason, now_ns);
            return .slice;
        }
        if (!self.boundary_due or event.topic != @backingInt(proto.Topic.stop)) return .other;
        const stop = proto.decode(proto.Stopped, event.payload) catch return .other;
        if (stop.core != self.core or stop.reason != .count) return .other;
        self.boundary_due = false;
        return .boundary;
    }

    fn answered(self: *Run, result: proto.Client.Env.Result, now_ns: u64) void {
        const done = switch (result) {
            .ok => |bytes| proto.decode(proto.Advanced, bytes) catch return self.refuse(),
            .err => return self.refuse(),
        };
        self.arrived(done.to_ns -| done.from_ns, done.to_ns, done.address, done.reason, now_ns);
    }

    /// Take a finished slice: what it moved, where it left the core, and
    /// how the unit fits now. One accounting for both paths (RA8EMU-1196):
    /// a sync slice's boundary is the stop event behind its answer; an
    /// async slice's transport completion is its own boundary, and the stop
    /// event behind it stays with the status bar and the leaves.
    fn arrived(self: *Run, moved: u64, to_ns: u64, address: u32, reason: proto.StopReason, now_ns: u64) void {
        self.address = address;
        self.board_ns = to_ns;
        if (self.owed_ns) |owed| self.owed_ns = owed -| moved;
        // Board time that stands still has nothing more to pay this frame.
        if (moved == 0) self.until_ns = 0;
        const at_ns = if (self.answered_at) |when| when.load(.acquire) else now_ns;
        self.resize(at_ns -| self.sent_ns);
        if (self.slice_async and reason == .halt_requested) {
            // The job was preempted: the pause's halt is where it got to.
            self.lit = false;
            self.settled = address;
            return;
        }
        if (reason != .count) {
            self.lit = false;
            return;
        }
        if (self.slice_async) {
            if (!self.lit) self.settled = address;
            return;
        }
        self.boundary_due = true;
        if (!self.lit) self.settled = self.address;
    }

    fn refuse(self: *Run) void {
        self.lit = false;
        self.refused = true;
        self.settled = self.address;
    }

    /// Fit the unit to what the host just showed it can do.
    fn resize(self: *Run, took_ns: u64) void {
        if (took_ns > share_ns) {
            const fitted: u64 = @intCast(@as(u128, self.asked_ns) * share_ns / took_ns);
            self.unit_ns = @max(least_unit_ns, fitted);
            self.ceiling_ns = @min(frame_ns, self.unit_ns *| ceiling_factor);
            self.ease = ease_frames;
        } else if (took_ns <= share_ns / 2 and self.asked_ns == self.unit_ns) {
            self.unit_ns = @min(self.ceiling_ns, self.unit_ns * 2);
        }
    }
};
