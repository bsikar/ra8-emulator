//! Where the console pane is scrolled to (RA8EMU-206). A wheel turn up goes
//! back through the scrollback, a turn down comes forward, and at the
//! bottom the pane follows the output. Scrolled back, the view holds still
//! while new lines arrive: each one the log finishes (or drops off the top)
//! moves the offset back by one, so the same lines stay on screen.
const console_log = @import("console_log.zig");

/// Lines one wheel notch moves.
pub const step: f32 = 3;

pub const Scroll = struct {
    /// Finished lines below the pane's bottom row; 0 follows the output.
    back: usize = 0,
    /// Lines the log had finished, dropped ones included, when last read.
    seen: u64 = 0,
    /// The part of a line a fine wheel (a trackpad) has turned so far.
    rest: f32 = 0,

    /// A wheel turn of `dy` notches over the pane; up is positive.
    pub fn wheel(self: *Scroll, dy: f32, log: *const console_log.Log) void {
        self.follow(log);
        self.rest += dy * step;
        const whole: i64 = @intFromFloat(@trunc(self.rest));
        self.rest -= @floatFromInt(whole);
        const moved = @as(i64, @intCast(self.back)) + whole;
        self.back = @intCast(@max(moved, 0));
        self.clamp(log);
        // A turn past either end is spent, so turning back moves at once.
        if (self.back == 0) self.rest = @max(self.rest, 0);
        if (self.back == log.lines().len) self.rest = @min(self.rest, 0);
    }

    /// Catches up with the lines the log finished since the last read.
    pub fn follow(self: *Scroll, log: *const console_log.Log) void {
        const total = log.dropped + log.lines().len;
        if (self.back != 0) self.back += @intCast(total - self.seen);
        self.seen = total;
        self.clamp(log);
    }

    fn clamp(self: *Scroll, log: *const console_log.Log) void {
        self.back = @min(self.back, log.lines().len);
    }
};
