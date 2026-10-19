//! The seam the shell answers through each frame: the session is served on
//! the shell's own thread (session_worker.zig's inline drain) or on a
//! thread of its own, where the shell's call only hears how it fares.

/// One in-process session the shell answers each frame.
pub const Server = struct {
    context: *anyopaque,
    answerFn: *const fn (context: *anyopaque) anyerror!void,

    pub fn answer(self: Server) !void {
        return self.answerFn(self.context);
    }
};
