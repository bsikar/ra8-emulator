//! Paces a running emulation to the host window, one frame at a time
//! (RA8EMU-646). The engine keeps its own loop on its own thread and
//! charges each stretch here at the boundary; once the frame's share is
//! spent it parks until the window grants the next. The window steps only
//! while the engine is parked, so its scan of the board never races a
//! stretch, and neither backend's run loop has to be rebuilt to yield.
const std = @import("std");
const window_board = @import("window_board.zig");

pub const Pacer = struct {
    /// Instructions the window grants per frame.
    per_frame: u64,
    mutex: std.Thread.Mutex = .{},
    changed: std.Thread.Condition = .{},
    /// What is left of the current grant.
    left: u64 = 0,
    /// The engine is waiting at a boundary for a grant.
    parked: bool = false,
    /// The run has ended, for whatever reason the engine stopped.
    ended: bool = false,
    /// The window has gone; the engine should stop at its next boundary.
    quit: bool = false,

    /// Engine side, at each boundary: charge the stretch, and once the
    /// grant is spent wait for the next. Charging 0 before the first
    /// stretch holds the engine until the window's first step. False once
    /// the window has quit, so the run ends there.
    pub fn charge(self: *Pacer, instructions: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.left -|= instructions;
        while (self.left == 0 and !self.quit) {
            self.parked = true;
            self.changed.broadcast();
            self.changed.wait(&self.mutex);
        }
        self.parked = false;
        return !self.quit;
    }

    /// Engine side, once the run has ended, whatever ended it.
    pub fn finish(self: *Pacer) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.ended = true;
        self.changed.broadcast();
    }

    /// Window side: grant one frame and wait until the engine has spent it
    /// and parked, or the run has ended. False once it has ended.
    pub fn step(self: *Pacer) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.ended) return false;
        self.left = self.per_frame;
        self.parked = false;
        self.changed.broadcast();
        while (!self.ended and !(self.parked and self.left == 0)) self.changed.wait(&self.mutex);
        return !self.ended;
    }

    /// Window side, when it closes: release a parked engine to stop.
    pub fn stop(self: *Pacer) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.quit = true;
        self.changed.broadcast();
    }

    pub fn stepper(self: *Pacer) window_board.Stepper {
        return .{ .ctx = self, .step = stepThunk };
    }

    fn stepThunk(ctx: *anyopaque) bool {
        const self: *Pacer = @ptrCast(@alignCast(ctx));
        return self.step();
    }
};
