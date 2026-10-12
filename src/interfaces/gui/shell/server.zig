//! A session served in this process (local_session.zig), answering on the
//! shell's own thread between frames.

/// One in-process session the shell answers each frame.
pub const Server = struct {
    context: *anyopaque,
    answerFn: *const fn (context: *anyopaque) anyerror!void,

    pub fn answer(self: Server) !void {
        return self.answerFn(self.context);
    }
};
