//! The devices pane's side of a shown run (RA8EMU-703): the session the
//! pane plugs through, the rows it lists, and the park hook that applies
//! the queued changes on the engine's thread.
//!
//! The rows are what the run fitted: the Click module's IMU and gauge on
//! the touch line when `click` is set, then each `--attach`. The session's
//! plug hook is the post (plug_post.zig), so a click only queues; `park`
//! applies the queue through the board's own hook.
//!
//! A speed change (RA8EMU-184) waits for the park the same way, in the
//! speed post, and lands on the board's pacing there. It is taken by
//! `setSpeed` rather than Session.setSpeed: this session drives no core,
//! so it has no run budget to scale.
const std = @import("std");
const Board = @import("../../board/board.zig").Board;
const session_plug = @import("../../board/session_plug.zig");
const session_api = @import("../../debug/session_api.zig");
const devices_panel = @import("../../gui/devices_panel.zig");
const plug_post = @import("../../gui/plug_post.zig");
const speed_post = @import("../../gui/speed_post.zig");
const session_speed = @import("../../debug/session_speed.zig");
const pacing = @import("../../periph/time/pacing.zig");
const parts = @import("../../periph/model/parts.zig");
const request = @import("../../periph/model/request.zig");

/// Where `click` puts the module's parts (src/board/i2c.zig).
pub const click_imu: session_api.Endpoint = .{ .i2c = .{ .line = .touch, .address = 0x6B } };
pub const click_gauge: session_api.Endpoint = .{ .i2c = .{ .line = .touch, .address = 0x36 } };

pub const Devices = struct {
    arena: std.heap.ArenaAllocator,
    plugs: session_plug.Plugs,
    post: plug_post.PlugPost,
    speed: speed_post.SpeedPost,
    board: *Board,
    io: std.Io,
    session: session_api.Session = .{ .live = undefined },
    event_ns: std.atomic.Value(u64) = .init(0),
    rows: [request.max + 2]devices_panel.Row = undefined,
    panel: devices_panel.Panel = undefined,

    /// Builds in place: the session and the panel point into `self`.
    pub fn init(self: *Devices, allocator: std.mem.Allocator, io: std.Io, board: *Board, attaches: []const request.Request, click: bool) void {
        self.* = .{ .arena = .init(allocator), .plugs = undefined, .post = .{ .io = io }, .speed = .{ .io = io }, .board = board, .io = io };
        self.plugs = session_plug.Plugs.init(board, self.arena.allocator());
        self.event_ns.store(board.time.base.now(), .monotonic);
        self.session.attachEventClock(.{ .context = self, .nowFn = eventNow });
        self.session.attachPlugs(self.post.hook());
        var count: usize = 0;
        if (click) {
            self.rows[0] = .{ .at = click_imu, .part = parts.imu_name };
            self.rows[1] = .{ .at = click_gauge, .part = parts.gauge_name };
            count = 2;
        }
        for (attaches) |wanted| {
            self.rows[count] = .{ .at = wanted.at, .part = wanted.name };
            count += 1;
        }
        self.panel = .{ .session = &self.session, .rows = self.rows[0..count] };
    }

    pub fn deinit(self: *Devices) void {
        self.plugs.deinit();
        self.arena.deinit();
    }

    /// Window side: pace the run at `factor` times real time from the next
    /// park on. A factor --speed would refuse is refused here too.
    pub fn setSpeed(self: *Devices, factor: f64) !void {
        const change = try session_speed.Change.of(factor, 1);
        const hook = self.speed.hook();
        try hook.setFn(hook.context, change.milli);
    }

    /// Engine side, at each park: apply what the pane queued, then any
    /// speed change against the host clock.
    pub fn park(self: *Devices) void {
        self.event_ns.store(self.board.time.base.now(), .release);
        _ = self.post.apply(self.plugs.hook());
        _ = self.speed.apply(&self.board.run.pacing, self.board.time.base.now(), pacing.hostClock(self.io));
    }

    fn eventNow(context: *anyopaque) u64 {
        const self: *Devices = @ptrCast(@alignCast(context));
        return self.event_ns.load(.acquire);
    }
};
