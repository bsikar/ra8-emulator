//! The local session on a thread of its own. Served on the window's thread,
//! a run takes its time out of every frame: the window draws, and hears the
//! pointer, only as fast as the image runs. Here the session answers on its
//! own thread, over the same loopback made safe for two (shared_wire.zig),
//! so the window keeps its frame rate whatever a slice costs and the image
//! has a core to itself.
//!
//! Everything that reads or steps the board runs on this thread: the
//! session's requests, the per-user listener's outside clients and their gdb
//! servers (shell/hosted.zig), and the camera preview's sample
//! (preview_relay.zig). The shell only sends and takes frames.
const std = @import("std");
const rpc = @import("ra8_rpc_wire");
const host_worker = @import("ra8_host").worker;
const local_session = @import("local_session.zig");
const shared_wire = @import("shared_wire.zig");
const preview_relay = @import("preview_relay.zig");
const wall_clock = @import("wall_clock.zig");
const shell_camera = @import("shell/camera/camera.zig");
const Server = @import("shell/server.zig").Server;
const Shell = @import("shell/loop.zig").Shell;

/// How long an idle thread sleeps before it looks at the listener's sockets
/// again; a request from the shell wakes it at once.
const idle_wait_ms: i64 = 4;

pub const Worker = struct {
    io: std.Io,
    session: *local_session.LocalSession,
    wire: shared_wire.Wire,
    relay: preview_relay.Relay,
    /// The per-user listener's answer, taken on this thread too.
    listener: ?Server = null,
    thread: ?*host_worker.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    /// The thread ended on `failure`.
    failed: std.atomic.Value(bool) = .init(false),
    failure: anyerror = error.Unexpected,

    /// Put `session` behind the shared wire and hand back the shell's end
    /// of it. The worker must not move from here on: the wire's ends and
    /// the thread point at it.
    pub fn bind(self: *Worker, io: std.Io, allocator: std.mem.Allocator, session: *local_session.LocalSession, clock: wall_clock.Clock) rpc.Transport {
        self.* = .{ .io = io, .session = session, .wire = .{ .io = io, .loop = &session.loop, .clock = clock }, .relay = .{ .io = io, .allocator = allocator } };
        session.serveOn(self.wire.session());
        return self.wire.shell();
    }

    /// Take over what `shell` did with the session on its own thread: the
    /// answers, the listener, the run's slice sizing and the camera
    /// preview. The thread starts here.
    pub fn serveShell(self: *Worker, shell: *Shell) !void {
        shell.server = self.server();
        self.listener = shell.listener;
        shell.listener = null;
        shell.worker = self;
        if (shell.time) |time| time.run.answered_at = &self.wire.answered_ns;
        if (shell.camera) |camera| camera.preview_provider = .{ .context = self, .previewFn = preview };
        try self.start();
    }

    /// The same worker over `session` reopened in place (shell/rebuild.zig).
    /// Call it stopped.
    pub fn rebind(self: *Worker) void {
        self.wire = .{ .io = self.io, .loop = &self.session.loop, .clock = self.wire.clock };
        self.session.serveOn(self.wire.session());
    }

    pub fn start(self: *Worker) !void {
        self.stopping.store(false, .release);
        self.thread = try host_worker.spawn(run, self);
    }

    /// End the thread and wait for it; the session is the caller's again.
    pub fn stop(self: *Worker) void {
        const thread = self.thread orelse return;
        self.stopping.store(true, .release);
        self.wire.close();
        host_worker.join(thread);
        self.thread = null;
    }

    pub fn deinit(self: *Worker) void {
        self.stop();
        self.relay.deinit();
    }

    /// The shell's end of the session's wire.
    pub fn transport(self: *Worker) rpc.Transport {
        return self.wire.shell();
    }

    /// The worker as the shell's server: nothing to answer on the shell's
    /// thread, only the error that ended this one to pass on.
    pub fn server(self: *Worker) Server {
        return .{ .context = self, .answerFn = fares };
    }

    fn fares(context: *anyopaque) anyerror!void {
        const self: *Worker = @ptrCast(@alignCast(context));
        if (self.failed.load(.acquire)) return self.failure;
    }

    /// Sleep until the session sends or `timeout_ns` goes by. True when it
    /// sent, so the shell has arrivals to take.
    pub fn wait(self: *Worker, timeout_ns: u64) bool {
        const sent = if (self.wire.answered.waitTimeout(self.io, .{ .duration = .{ .raw = .fromNanoseconds(timeout_ns), .clock = .awake } })) true else |_| false;
        self.wire.answered.reset();
        return sent;
    }

    /// The camera preview, sampled on the session's thread.
    pub fn preview(context: *anyopaque) ?shell_camera.PreviewFrame {
        const self: *Worker = @ptrCast(@alignCast(context));
        const frame = self.relay.latest();
        self.wire.asked.set(self.io);
        return frame;
    }

    fn run(context: *anyopaque) void {
        const self: *Worker = @ptrCast(@alignCast(context));
        while (!self.stopping.load(.acquire)) {
            self.wire.asked.reset();
            const worked = self.turn() catch |err| {
                if (self.stopping.load(.acquire)) return;
                self.failure = err;
                self.failed.store(true, .release);
                return;
            };
            if (worked) continue;
            self.wire.asked.waitTimeout(self.io, .{ .duration = .{ .raw = .fromMilliseconds(idle_wait_ms), .clock = .awake } }) catch {};
        }
    }

    /// One turn: every frame the shell has sent, the listener's clients,
    /// the preview. True when the shell's frames gave it work.
    fn turn(self: *Worker) !bool {
        const worked = try self.session.serve();
        if (self.listener) |listener| try listener.answer();
        self.relay.offer(self.sample());
        return worked;
    }

    fn sample(self: *Worker) ?shell_camera.PreviewFrame {
        const frame = self.session.cameraPreview() orelse return null;
        return .{ .width = frame.width, .height = frame.height, .pixels = frame.pixels };
    }
};
