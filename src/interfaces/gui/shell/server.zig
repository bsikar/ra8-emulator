//! A session served in this process (local_session.zig), answering on the
//! shell's own thread between frames.
const local_session = @import("../local_session.zig");

/// One in-process session the shell answers each frame.
pub const Server = struct {
    context: *anyopaque,
    answerFn: *const fn (context: *anyopaque) anyerror!void,

    pub fn answer(self: Server) !void {
        return self.answerFn(self.context);
    }
};

/// `session` as the shell answers it: in this process, on the shell's thread.
pub fn served(session: *local_session.LocalSession) Server {
    return .{ .context = session, .answerFn = answerLocal };
}

fn answerLocal(context: *anyopaque) anyerror!void {
    const session: *local_session.LocalSession = @ptrCast(@alignCast(context));
    return session.answer();
}
