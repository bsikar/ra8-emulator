//! The local session's loopback, shared by two threads (session_worker.zig).
//! The shell's end never waits: a full pipe is back-pressure it reads as
//! such. The session's end waits for room instead, because the shell takes
//! its arrivals a frame at a time and a busy run sends more than one frame
//! of them. Each end sets an event as it sends, so the other can sleep until
//! there is something to take.
const std = @import("std");
const rpc = @import("ra8_rpc_wire");
const wall_clock = @import("wall_clock.zig");

/// How long the session's end sleeps on a full pipe before it looks again.
const room_wait_ms: i64 = 20;

pub const Wire = struct {
    io: std.Io,
    loop: *rpc.Loopback,
    /// The shell's wall clock: when the session last sent is read on it.
    clock: wall_clock.Clock,
    mutex: std.Io.Mutex = .init,
    /// The shell sent: the session has something to answer.
    asked: std.Io.Event = .unset,
    /// The session sent: the shell has something to take.
    answered: std.Io.Event = .unset,
    /// The shell took bytes: a session waiting for room may send.
    room: std.Io.Event = .unset,
    /// The session is going away: its end stops waiting and reads as down.
    closing: std.atomic.Value(bool) = .init(false),
    /// When the session last put bytes on the wire, on `clock`.
    answered_ns: std.atomic.Value(u64) = .init(0),

    /// The shell's end. It points at this `Wire`, so it must not move.
    pub fn shell(self: *Wire) rpc.Transport {
        return .{ .ctx = self, .vtable = &.{ .send = ask, .receive = take, .poll = waiting } };
    }

    /// The session's end, for the thread that answers.
    pub fn session(self: *Wire) rpc.Transport {
        return .{ .ctx = self, .vtable = &.{ .send = answer, .receive = hear, .poll = asking } };
    }

    /// Stop the session's end waiting, for good.
    pub fn close(self: *Wire) void {
        self.closing.store(true, .release);
        self.room.set(self.io);
        self.asked.set(self.io);
    }

    fn from(ctx: *anyopaque) *Wire {
        return @ptrCast(@alignCast(ctx));
    }

    fn ask(ctx: *anyopaque, bytes: []const u8) rpc.Transport.Error!void {
        const self = from(ctx);
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            try self.loop.a().send(bytes);
        }
        self.asked.set(self.io);
    }

    fn take(ctx: *anyopaque, into: []u8) rpc.Transport.Error!usize {
        const self = from(ctx);
        const count = taken: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            break :taken try self.loop.a().receive(into);
        };
        if (count != 0) self.room.set(self.io);
        return count;
    }

    fn waiting(ctx: *anyopaque) usize {
        const self = from(ctx);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.loop.a().poll();
    }

    /// All of `bytes`, once the shell has made room for them.
    fn answer(ctx: *anyopaque, bytes: []const u8) rpc.Transport.Error!void {
        const self = from(ctx);
        while (true) {
            if (self.closing.load(.acquire)) return error.LinkDown;
            self.room.reset();
            if (self.put(bytes)) break;
            self.room.waitTimeout(self.io, .{ .duration = .{ .raw = .fromMilliseconds(room_wait_ms), .clock = .awake } }) catch {};
        }
        self.answered.set(self.io);
    }

    fn put(self: *Wire, bytes: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.loop.b().send(bytes) catch return false;
        self.answered_ns.store(self.clock.now(), .release);
        return true;
    }

    fn hear(ctx: *anyopaque, into: []u8) rpc.Transport.Error!usize {
        const self = from(ctx);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.loop.b().receive(into);
    }

    fn asking(ctx: *anyopaque) usize {
        const self = from(ctx);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.loop.b().poll();
    }
};
