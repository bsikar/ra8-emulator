//! The board's side of a session speed change when the session and the
//! engine share one thread, as in the debugger (RA8EMU-184): the change
//! lands on the board's pacing at once, between commands. A shown run,
//! whose engine has a thread of its own, goes through gui/speed_post.zig.
const session_api = @import("../debug/session_api.zig");
const clocks = @import("../periph/clocks.zig");

pub const BoardSpeed = struct {
    time: *clocks.Time,
    clock: clocks.pacer.Clock,

    pub fn hook(self: *BoardSpeed) session_api.SpeedHook {
        return .{ .context = self, .setFn = set };
    }

    /// Re-anchor the pacer at the current virtual time, so time carries on
    /// and only its rate against the wall changes; an unpaced board starts
    /// pacing here.
    fn set(context: *anyopaque, milli: u64) anyerror!void {
        const self: *BoardSpeed = @ptrCast(@alignCast(context));
        const now_ns = self.time.base.now();
        if (self.time.pacing) |*pacing| {
            pacing.setSpeed(now_ns, milli);
        } else {
            self.time.pacing = clocks.pacing.Pacing.start(self.clock, now_ns, milli);
        }
    }
};
