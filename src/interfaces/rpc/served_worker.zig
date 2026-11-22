//! Dedicated single-producer execution worker thread for `ra8_emulator serve`
//! (RA8EMU-1238). The worker owns `plane.pump` while RPC/GDB turns bracket at
//! slice boundaries (`acquire`/`release`) so virtual-time emulation runs decoupled
//! from WebSocket frame serialization and browser frame pacing.
const board_mod = @import("ra8_board");
const served_setup = @import("served_setup.zig");
const session = @import("ra8_session");
const std = @import("std");

const Board = board_mod.board.Board;
const transport_mod = session.transport;

pub const worker_slice_ns: u64 = 2_000_000;

pub const Worker = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    plane: *transport_mod.Transport,
    wall: transport_mod.Wall,
    run_policy: session.run.policy.RunPolicy = .{},
    pace_clock: session.run.pacer.HostClock,
    board_speed: session.board.speed.BoardSpeed = undefined,
    mutex: std.Io.Mutex = .init,
    work_cond: std.Io.Condition = .init,
    rpc_cond: std.Io.Condition = .init,
    closing: bool = false,
    worker_busy: bool = false,
    rpc_waiting: u32 = 0,
    active_job: std.atomic.Value(bool) = .init(false),
    latched_finished: ?transport_mod.Finished = null,
    latched_error: ?anyerror = null,
    slices_pumped: u64 = 0,
    thread: ?std.Thread = null,

    pub fn open(
        gpa: std.mem.Allocator,
        io: std.Io,
        board: *Board,
        sess: *session.api.Session,
        plane: *transport_mod.Transport,
        wall: transport_mod.Wall,
    ) !*Worker {
        const self = try gpa.create(Worker);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .plane = plane,
            .wall = wall,
            .pace_clock = session.run.pacer.HostClock.init(io),
        };
        self.run_policy.attach(board);
        errdefer board.run_hook = null;
        self.board_speed = .{
            .time = &board.time,
            .paced = &self.run_policy.pacing,
            .clock = self.pace_clock.clock(),
        };
        sess.speed = self.board_speed.hook();
        errdefer sess.speed = null;
        self.active_job.store(plane.job != null, .release);
        self.thread = try std.Thread.spawn(.{}, workLoop, .{self});
        return self;
    }

    pub fn close(self: *Worker, board: *Board, sess: *session.api.Session) void {
        self.mutex.lockUncancelable(self.io);
        self.closing = true;
        self.work_cond.broadcast(self.io);
        self.rpc_cond.broadcast(self.io);
        self.mutex.unlock(self.io);
        if (self.thread) |thread| thread.join();
        sess.speed = null;
        board.run_hook = null;
        self.gpa.destroy(self);
    }

    /// Block at the next worker slice boundary; pairs with `release()`.
    pub fn acquire(self: *Worker) void {
        self.mutex.lockUncancelable(self.io);
        self.rpc_waiting += 1;
        while (self.worker_busy) {
            self.rpc_cond.waitUncancelable(self.io, &self.mutex);
        }
    }

    /// Resume the worker thread if a transport job is active.
    pub fn release(self: *Worker) void {
        self.rpc_waiting -= 1;
        const has_job = self.plane.job != null;
        self.active_job.store(has_job, .release);
        if (self.rpc_waiting == 0 and has_job and !self.closing) {
            self.work_cond.signal(self.io);
        }
        self.mutex.unlock(self.io);
    }

    pub fn isActive(self: *const Worker) bool {
        return self.active_job.load(.acquire);
    }

    pub fn slicesPumped(self: *Worker) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.slices_pumped;
    }

    /// Return the current transport report plus any latched finish/error from the worker.
    /// Caller must hold `acquire()`.
    pub fn takePumped(self: *Worker) !transport_mod.Pumped {
        if (self.latched_error) |err| {
            self.latched_error = null;
            return err;
        }
        const fin = self.latched_finished;
        self.latched_finished = null;
        return .{ .report = self.plane.report(), .finished = fin, .drain = false };
    }

    fn workLoop(self: *Worker) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (!self.closing) {
            if (self.rpc_waiting > 0 or self.plane.job == null) {
                self.active_job.store(self.plane.job != null, .release);
                self.work_cond.waitUncancelable(self.io, &self.mutex);
                continue;
            }
            self.worker_busy = true;
            self.mutex.unlock(self.io);
            const now = self.wall.nowFn(self.wall.context);
            const outcome = self.plane.pump(self.wall, now + worker_slice_ns);
            self.mutex.lockUncancelable(self.io);
            self.worker_busy = false;
            self.recordOutcome(outcome);
            self.active_job.store(self.plane.job != null, .release);
            if (self.rpc_waiting > 0) self.rpc_cond.broadcast(self.io);
        }
    }

    fn recordOutcome(self: *Worker, outcome: anyerror!transport_mod.Pumped) void {
        if (outcome) |pumped| {
            self.slices_pumped += 1;
            if (pumped.finished) |fin| self.latched_finished = fin;
        } else |err| {
            self.latched_error = err;
            self.plane.cancel();
        }
    }
};

pub fn attach(served: *served_setup.Served) !void {
    if (served.worker != null) return;
    const plane = served.context.transport orelse return error.MissingTransport;
    const wall = served.context.wall orelse return error.MissingWall;
    const worker = try Worker.open(
        served.gpa,
        served.io,
        served.owner.board(),
        served.owner.session(),
        plane,
        wall,
    );
    served.worker = worker;
    served.context.worker = worker;
    served.context.transport_async = true;
}

pub fn detach(served: *served_setup.Served) void {
    const worker = served.worker orelse return;
    served.worker = null;
    served.context.worker = null;
    served.context.transport_async = false;
    worker.close(served.owner.board(), served.owner.session());
}
