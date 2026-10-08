//! Paces a running emulation to the host window, one frame at a time
//! (RA8EMU-646). The engine keeps its own loop on its own thread and
//! charges each stretch here at the boundary; once the frame's share is
//! spent it parks until the window grants the next. The engine publishes
//! the board at each park (RA8EMU-227), so the shown window grants without
//! waiting and never holds the engine to its own frame; `step` still waits
//! for the stretch, for callers that read the board themselves. Neither
//! backend's run loop has to be rebuilt to yield.
const std = @import("std");
const window_board = @import("window_board.zig");

/// Engine side, run where the engine stops: just before it parks for the
/// next grant and once the run has ended (RA8EMU-227). The window reads
/// what it published, so the board is only ever touched on the engine's
/// own thread.
pub const Hook = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque) void,
};

pub const Pacer = struct {
    /// Instructions the window grants per frame.
    per_frame: u64,
    /// The engine and window threads lock through it; neither cancels.
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    /// What is left of the current grant.
    left: u64 = 0,
    /// The engine is waiting at a boundary for a grant.
    parked: bool = false,
    /// The run has ended, for whatever reason the engine stopped.
    ended: bool = false,
    /// The window has gone; the engine should stop at its next boundary.
    quit: bool = false,
    /// Runs once at each park and once at the end, on the engine thread.
    at_park: ?Hook = null,

    /// Engine side, at each boundary: charge the stretch, and once the
    /// grant is spent wait for the next. Charging 0 before the first
    /// stretch holds the engine until the window's first step. False once
    /// the window has quit, so the run ends there.
    pub fn charge(self: *Pacer, instructions: u64) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.left -|= instructions;
        if (self.left == 0 and !self.quit) self.park();
        while (self.left == 0 and !self.quit) {
            self.parked = true;
            self.changed.broadcast(self.io);
            self.changed.wait(self.io, &self.mutex) catch {};
        }
        self.parked = false;
        return !self.quit;
    }

    /// Engine side, once the run has ended, whatever ended it.
    pub fn finish(self: *Pacer) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.park();
        self.ended = true;
        self.changed.broadcast(self.io);
    }

    /// Window side: grant one frame and wait until the engine has spent it
    /// and parked, or the run has ended. False once it has ended.
    pub fn step(self: *Pacer) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.ended) return false;
        self.left = self.per_frame;
        self.parked = false;
        self.changed.broadcast(self.io);
        while (!self.ended and !(self.parked and self.left == 0)) self.changed.wait(self.io, &self.mutex) catch {};
        return !self.ended;
    }

    /// Window side, without waiting: when the engine has spent its grant
    /// and parked, grant the next frame; while it is still running, leave
    /// it be, so it never gets more than one frame ahead of the window.
    /// False once the run has ended.
    pub fn grant(self: *Pacer) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.ended) return false;
        if (self.parked and self.left == 0) {
            self.left = self.per_frame;
            self.parked = false;
            self.changed.broadcast(self.io);
        }
        return true;
    }

    /// Window side, when it closes: release a parked engine to stop.
    pub fn stop(self: *Pacer) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.quit = true;
        self.changed.broadcast(self.io);
    }

    fn park(self: *Pacer) void {
        if (self.at_park) |hook| hook.call(hook.ctx);
    }

    pub fn stepper(self: *Pacer) window_board.Stepper {
        return .{ .ctx = self, .step = stepThunk };
    }

    fn stepThunk(ctx: *anyopaque) bool {
        const self: *Pacer = @ptrCast(@alignCast(ctx));
        return self.step();
    }

    /// A stepper that grants without waiting, for a window that only reads
    /// what the engine published.
    pub fn granter(self: *Pacer) window_board.Stepper {
        return .{ .ctx = self, .step = grantThunk };
    }

    fn grantThunk(ctx: *anyopaque) bool {
        const self: *Pacer = @ptrCast(@alignCast(ctx));
        return self.grant();
    }
};
