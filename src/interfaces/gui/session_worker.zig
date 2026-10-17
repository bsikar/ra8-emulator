//! The local session on a thread of its own. Served on the window's thread,
//! a run takes its time out of every frame: the window draws, and hears the
//! pointer, only as fast as the image runs. Here the session answers on its
//! own thread: the shell's typed requests wait in a mailbox
//! (local_native_link.zig) this thread drains straight into the served
//! handlers, so the window keeps its frame rate whatever a slice costs.
//!
//! Everything that reads or steps the board runs on this thread: the
//! session's requests, the per-user listener's outside clients and their gdb
//! servers (shell/hosted.zig), and the camera preview's sample
//! (preview_relay.zig). The shell only sends and takes frames.
const std = @import("std");
const host_worker = @import("ra8_host").worker;
const local_session = @import("local_session.zig");
const local_native_link = @import("local_native_link.zig");
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
    gpa: std.mem.Allocator,
    clock: wall_clock.Clock,
    session: *local_session.LocalSession,
    native: local_native_link.Native,
    relay: preview_relay.Relay,
    /// The per-user listener's answer, taken on this thread too.
    listener: ?Server = null,
    thread: ?*host_worker.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    /// The thread ended on `failure`.
    failed: std.atomic.Value(bool) = .init(false),
    failure: anyerror = error.Unexpected,

    /// Put `session` behind the native mailbox and point the shell's link
    /// at it (main.zig opens it with openNative). The worker must not move
    /// from here on: the mailbox and the thread point at it.
    pub fn bind(self: *Worker, io: std.Io, allocator: std.mem.Allocator, session: *local_session.LocalSession, clock: wall_clock.Clock) void {
        self.* = .{ .io = io, .gpa = allocator, .clock = clock, .session = session, .native = local_native_link.Native.init(io, allocator, clock, &session.setup.context), .relay = .{ .io = io, .allocator = allocator } };
    }

    /// Take over what `shell` did with the session on its own thread: the
    /// answers, the listener, the run's slice sizing and the camera
    /// preview. The thread starts here.
    pub fn serveShell(self: *Worker, shell: *Shell) !void {
        shell.server = self.server();
        self.listener = shell.listener;
        shell.listener = null;
        shell.worker = self;
        if (shell.time) |time| time.run.answered_at = &self.native.answered_ns;
        if (shell.camera) |camera| camera.preview_provider = .{ .context = self, .previewFn = preview };
        try self.start();
    }

    /// The same worker over `session` reopened in place (shell/rebuild.zig).
    /// Call it stopped.
    pub fn rebind(self: *Worker) void {
        self.native.deinit();
        self.native = local_native_link.Native.init(self.io, self.gpa, self.clock, &self.session.setup.context);
    }

    pub fn start(self: *Worker) !void {
        self.stopping.store(false, .release);
        self.thread = try host_worker.spawn(run, self);
    }

    /// End the thread and wait for it; the session is the caller's again.
    pub fn stop(self: *Worker) void {
        const thread = self.thread orelse return;
        self.stopping.store(true, .release);
        self.native.shutdown();
        host_worker.join(thread);
        self.thread = null;
    }

    pub fn deinit(self: *Worker) void {
        self.stop();
        self.native.deinit();
        self.relay.deinit();
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
        return self.native.wait(timeout_ns);
    }

    /// The camera preview, sampled on the session's thread.
    pub fn preview(context: *anyopaque) ?shell_camera.PreviewFrame {
        const self: *Worker = @ptrCast(@alignCast(context));
        const frame = self.relay.latest();
        self.native.wake();
        return frame;
    }

    fn run(context: *anyopaque) void {
        const self: *Worker = @ptrCast(@alignCast(context));
        while (!self.stopping.load(.acquire)) {
            self.native.asked.reset();
            const worked = self.turn() catch |err| {
                if (self.stopping.load(.acquire)) return;
                self.failure = err;
                self.failed.store(true, .release);
                return;
            };
            if (worked) continue;
            self.native.asked.waitTimeout(self.io, .{ .duration = .{ .raw = .fromMilliseconds(idle_wait_ms), .clock = .awake } }) catch {};
        }
    }

    /// One turn: the mailbox's requests, the listener's clients, the
    /// preview. True when the shell's requests gave it work.
    fn turn(self: *Worker) !bool {
        const worked = try self.native.serve();
        if (self.listener) |listener| try listener.answer();
        self.relay.offer(self.sample());
        return worked;
    }

    fn sample(self: *Worker) ?shell_camera.PreviewFrame {
        const frame = self.session.cameraPreview() orelse return null;
        return .{ .width = frame.width, .height = frame.height, .pixels = frame.pixels };
    }
};
