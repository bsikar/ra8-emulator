//! The shell's native link to its local session (slice 15): the typed
//! requests the window thread sends wait in a mailbox that the session's
//! thread drains straight into the served handlers (local_native.zig), and
//! the arrivals the handlers and feeds produce wait in a queue the window
//! takes one per pump. No loopback pipes and no byte framing cross the
//! boundary; the request values and the owned arrivals do. The window
//! never blocks and never runs the session, so a long advance on the
//! session's thread leaves the window's frame rate alone.
const std = @import("std");
const proto = @import("ra8_rpc").session.rpc;
const session_server = @import("ra8_rpc").session.server;
const local_native = @import("local_native.zig");
const wall_clock = @import("wall_clock.zig");

pub const Arrival = local_native.Arrival;

/// How many requests may wait to be dispatched at once: the same cap the
/// wire client's pending table gives the shell.
pub const max_requests = proto.pending_slots;

/// How many arrivals may wait to be taken at once: what a busy run
/// produces between the window's frames.
pub const max_arrivals = 64;

/// The widest request the routes take, computed so a mailbox slot always
/// fits every call the shell can name.
fn widestArgs() usize {
    var widest = 0;
    inline for (session_server.routes) |route| {
        const handler = route[1];
        const info = @typeInfo(@TypeOf(handler)).@"fn";
        if (info.param_types.len > 1) {
            if (info.param_types[1]) |Args| {
                if (@sizeOf(Args) > widest) widest = @sizeOf(Args);
            }
        }
    }
    return widest;
}

/// The mailbox slot's byte width, with room for any alignment the request
/// types ask for.
pub const max_args = widestArgs();

pub const Native = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    /// The shell's wall clock: when the session last handed an arrival
    /// over is read on it.
    clock: wall_clock.Clock,
    /// The session's end: dispatches straight to the handlers. Only the
    /// session's thread dispatches and pumps it, and only under `mutex`,
    /// which the window's sends and takes also hold.
    link: local_native.Link,
    mutex: std.Io.Mutex = .init,
    /// The window sent: the session's thread has requests to dispatch.
    asked: std.Io.Event = .unset,
    /// The session handed arrivals over: the window may take them.
    answered: std.Io.Event = .unset,
    /// When the session last handed an arrival to the window, on `clock`.
    answered_ns: std.atomic.Value(u64) = .init(0),
    /// The session's thread is going away: `serve` stops and the window's
    /// next pumps drain what is left.
    stopping: std.atomic.Value(bool) = .init(false),
    /// Requests waiting to be dispatched, oldest first.
    slots: [max_requests]Slot = undefined,
    head: usize = 0,
    count: usize = 0,
    /// Arrivals waiting to be taken, oldest first.
    ring: [max_arrivals]Arrival = undefined,
    ring_head: usize = 0,
    ring_count: usize = 0,
    /// The last arrival handed to the window, freed by the next pump.
    taken: ?[]const u8 = null,

    const Slot = struct {
        args: [max_args]u8 align(16),
        apply: *const fn (args: *const anyopaque, link: *local_native.Link) anyerror!u32,
    };

    pub fn init(io: std.Io, gpa: std.mem.Allocator, clock: wall_clock.Clock, context: *session_server.Context) Native {
        // There is no greeting on the native path, so the served context is
        // told the contract here: this host's client speaks the queued
        // advance (RA8EMU-1196), like the hosted listener's frame loop.
        context.transport_async = true;
        return .{ .io = io, .gpa = gpa, .clock = clock, .link = local_native.Link.init(gpa, context) };
    }

    /// Poke the session's thread: a preview to relay, or a shutdown asked.
    pub fn wake(self: *Native) void {
        self.asked.set(self.io);
    }

    /// The session's thread is going away; `serve` stops at its next step.
    pub fn shutdown(self: *Native) void {
        self.stopping.store(true, .release);
        self.wake();
    }

    /// The window's wait: true when the session handed arrivals over.
    pub fn wait(self: *Native, timeout_ns: u64) bool {
        const got = if (self.answered.waitTimeout(self.io, .{ .duration = .{ .raw = .fromNanoseconds(timeout_ns), .clock = .awake } })) true else |_| false;
        self.answered.reset();
        return got;
    }

    pub fn deinit(self: *Native) void {
        self.link.deinit();
        if (self.taken) |bytes| self.gpa.free(bytes);
        var i: usize = 0;
        while (i < self.ring_count) : (i += 1) {
            switch (self.ring[(self.ring_head + i) % max_arrivals]) {
                .response => |r| if (r.result == .ok) self.gpa.free(r.result.ok),
                .event => |e| self.gpa.free(e.payload),
            }
        }
    }

    /// The window's send: copy `args` into a slot and wake the session's
    /// thread. A full mailbox is back-pressure, not a broken session, the
    /// same shape the wire client's pending table gives. The id returned
    /// is the one the dispatch will queue the reply under.
    pub fn send(self: *Native, comptime Args: type, comptime method: proto.Method, args: Args) anyerror!u32 {
        comptime std.debug.assert(@sizeOf(Args) <= max_args);
        comptime std.debug.assert(@alignOf(Args) <= 16);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.count >= max_requests) return error.TableFull;
        const slot = &self.slots[(self.head + self.count) % max_requests];
        slot.* = .{ .args = undefined, .apply = Applier(Args, method).apply };
        @memcpy(slot.args[0..@sizeOf(Args)], std.mem.asBytes(&args));
        const id: u32 = @intCast(self.link.next_id + self.count);
        self.count += 1;
        self.asked.set(self.io);
        return id;
    }

    /// The session's thread's step: dispatch what the window queued while
    /// the reply queue has room, then hand everything the session owes to
    /// the window's ring. A full ring stops the handover; the rest stays
    /// queued for the next step. True when a request was dispatched, so
    /// the caller knows there may be more work right behind it.
    pub fn serve(self: *Native) anyerror!bool {
        if (self.stopping.load(.acquire)) return false;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var dispatched = false;
        while (self.count > 0 and self.link.pendingCount() < proto.pending_slots) {
            const slot = &self.slots[self.head];
            const args: *const anyopaque = @ptrCast(&slot.args);
            _ = slot.apply(args, &self.link) catch |err| return err;
            self.head = (self.head + 1) % max_requests;
            self.count -= 1;
            dispatched = true;
        }
        var grew = false;
        while (self.ring_count < max_arrivals) {
            const arrival = (try self.link.pump()) orelse break;
            self.link.releaseTaken();
            self.ring[(self.ring_head + self.ring_count) % max_arrivals] = arrival;
            self.ring_count += 1;
            grew = true;
        }
        if (grew) {
            self.answered_ns.store(self.clock.now(), .release);
            self.answered.set(self.io);
        }
        return dispatched;
    }

    /// The window's pump: take one arrival the session owes, oldest
    /// first. A slice inside it lives until the next pump.
    pub fn pump(self: *Native) !?Arrival {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.taken) |bytes| {
            self.gpa.free(bytes);
            self.taken = null;
        }
        if (self.ring_count == 0) return null;
        const arrival = self.ring[self.ring_head];
        self.ring_head = (self.ring_head + 1) % max_arrivals;
        self.ring_count -= 1;
        switch (arrival) {
            .response => |r| if (r.result == .ok) {
                self.taken = r.result.ok;
            },
            .event => |e| self.taken = e.payload,
        }
        return arrival;
    }
};

/// The comptime closure that dispatches one request type: the mailbox
/// stores only the arguments and this function pointer, so no byte
/// encoding crosses the thread boundary.
fn Applier(comptime Args: type, comptime method: proto.Method) type {
    return struct {
        fn apply(args: *const anyopaque, link: *local_native.Link) anyerror!u32 {
            const typed: *const Args = @ptrCast(@alignCast(args));
            return link.send(Args, method, typed.*);
        }
    };
}
