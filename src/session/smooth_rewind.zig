//! Smooth rewind engine and Pause exactness coordinator (Slice 22.3).
//! Integrates reverse clock frame playback with exact machine position
//! materialization on Pause (via reverse window or checkpoint replay).
const std = @import("std");
const api = @import("api.zig");
const frame_decoder = @import("history/frame_decoder.zig");
const window_engine = @import("history/window_engine.zig");
const position_mod = @import("history/position.zig");
const checkpoint_picture = @import("history/checkpoint_picture.zig");
const rewind_segment = @import("rewind_segment.zig");

pub const Position = position_mod.Position;
pub const FrameDecoder = frame_decoder.FrameDecoder;
pub const DecodedFrame = frame_decoder.DecodedFrame;
pub const TickResult = frame_decoder.TickResult;
pub const Status = frame_decoder.Status;
pub const ReverseWindow = window_engine.ReverseWindow;
/// Where a scan of the panel as the machine stands comes from.
pub const ScanSource = checkpoint_picture.Source;

/// The history's pinned pictures, as the application serves them: a refresh
/// that reads the committed log's picture records into the index, and the
/// object space's bytes by name.
pub const PictureSources = struct {
    context: *anyopaque,
    refreshFn: *const fn (context: *anyopaque, index: *checkpoint_picture.Index) anyerror!void,
    objectFn: *const fn (context: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror![]u8,
};

pub const State = enum {
    stopped,
    playing_backward,
    paused,
};

/// Custom restore handler for checkpoint replay when outside reverse window.
pub const CheckpointRestoreHook = struct {
    context: *anyopaque,
    restoreFn: *const fn (context: *anyopaque, target: Position) anyerror!void,

    pub fn restore(self: CheckpointRestoreHook, target: Position) anyerror!void {
        return self.restoreFn(self.context, target);
    }
};

pub const SmoothRewindEngine = struct {
    allocator: std.mem.Allocator,
    session: *api.Session,
    decoder: FrameDecoder,
    reverse_window: ?*ReverseWindow = null,
    restore_hook: ?CheckpointRestoreHook = null,
    current_frame: ?DecodedFrame = null,
    status: State = .stopped,
    scan: ?ScanSource = null,
    picture_index: checkpoint_picture.Index,
    picture_sources: ?PictureSources = null,
    /// Segments decoded silently, and windows they filled, for the status.
    decoded_segments: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, session: *api.Session) SmoothRewindEngine {
        return .{
            .allocator = allocator,
            .session = session,
            .decoder = FrameDecoder.init(allocator),
            .picture_index = checkpoint_picture.Index.init(allocator),
        };
    }

    pub fn deinit(self: *SmoothRewindEngine) void {
        if (self.current_frame) |*f| f.deinit(self.allocator);
        self.current_frame = null;
        self.decoder.deinit();
        self.picture_index.deinit();
    }

    pub fn attachWindow(self: *SmoothRewindEngine, win: ?*ReverseWindow) void {
        self.reverse_window = win;
    }

    /// Binds the pictures the history pinned, the scan that decodes a
    /// segment's windows, and the frame cache and index the lookups read.
    pub fn attachSources(self: *SmoothRewindEngine, pictures: ?PictureSources, scan: ?ScanSource) void {
        self.picture_sources = pictures;
        self.scan = scan;
        if (pictures) |p| {
            self.decoder.bindPictures(&self.picture_index, .{ .context = p.context, .getFn = p.objectFn });
        } else self.decoder.bindPictures(null, null);
    }

    pub fn attachRestoreHook(self: *SmoothRewindEngine, hook: ?CheckpointRestoreHook) void {
        self.restore_hook = hook;
    }

    pub fn isBusy(self: *const SmoothRewindEngine) bool {
        return self.status == .playing_backward;
    }

    /// Starts backward playback at the requested speed factor.
    pub fn start(self: *SmoothRewindEngine, speed: f64) !void {
        const cur_ns = if (self.decoder.cursor_ns > 0)
            self.decoder.cursor_ns
        else if (self.session.now()) |now_val|
            now_val
        else |_|
            0;
        self.decoder.temp_checkpoints.clear();
        if (self.picture_sources) |p| p.refreshFn(p.context, &self.picture_index) catch {};
        self.decoder.setCursorNs(cur_ns);
        self.decoder.setSpeed(speed);
        self.status = .playing_backward;
        // Prime the current frame at the start cursor.
        if (try self.decoder.lookupFrame(cur_ns)) |frame| {
            if (self.current_frame) |*f| f.deinit(self.allocator);
            self.current_frame = frame;
        }
    }

    pub fn setSpeed(self: *SmoothRewindEngine, speed: f64) void {
        self.decoder.setSpeed(speed);
    }

    pub fn setMaxSpeed(self: *SmoothRewindEngine) void {
        self.decoder.setMaxSpeed();
    }

    /// Advances the reverse clock and updates the displayed frame.
    pub fn tick(self: *SmoothRewindEngine, dt_wall_ns: u64) !TickResult {
        if (self.status != .playing_backward) {
            return .{
                .cursor_ns = self.decoder.cursor_ns,
                .frame = self.current_frame,
                .status = .ok,
                .mode = self.decoder.mode,
            };
        }

        const advance_res = self.decoder.advanceClock(dt_wall_ns);

        // Reuse current frame if still valid for the updated cursor
        if (self.current_frame) |cur| {
            const mode_match = (self.decoder.mode == .smooth) or (cur.source == .checkpoint_picture);
            if (self.decoder.cursor_ns >= cur.virtual_ns and advance_res == .ok and mode_match) {
                return .{
                    .cursor_ns = self.decoder.cursor_ns,
                    .frame = self.current_frame,
                    .status = .ok,
                    .mode = self.decoder.mode,
                };
            }
        }

        const maybe_frame = try self.present();
        if (maybe_frame) |frame| {
            if (self.current_frame) |*f| f.deinit(self.allocator);
            self.current_frame = frame;
        }

        if (advance_res == .history_start) {
            self.status = .paused;
        }

        return .{
            .cursor_ns = self.decoder.cursor_ns,
            .frame = self.current_frame,
            .status = advance_res,
            .mode = self.decoder.mode,
        };
    }

    /// The frame the cursor shows. In smooth mode a cursor the cache and the
    /// windows already decoded cannot answer within one window of the
    /// frame is decoded silently from the nearest restore point; the lag
    /// the shown frame has behind the cursor, past a window's width, feeds
    /// the hysteresis that moves between smooth and keyframes-only.
    fn present(self: *SmoothRewindEngine) !?DecodedFrame {
        const cursor = self.decoder.cursor_ns;
        const window: u64 = frame_decoder.bucketWidthNs(self.decoder.speed);
        var found = try self.decoder.lookupFrame(cursor);
        if (self.decoder.mode == .smooth and self.stale(found, cursor, window)) {
            const filled = rewind_segment.decode(self, cursor) catch 0;
            if (filled > 0) {
                self.decoded_segments += 1;
                if (found) |*old| old.deinit(self.allocator);
                found = try self.decoder.lookupFrame(cursor);
            }
        }
        const age: i64 = if (found) |f| @intCast(cursor -| f.virtual_ns) else @intCast(window);
        _ = self.decoder.updateHysteresis(age - @as(i64, @intCast(window)));
        return found;
    }

    fn stale(self: *const SmoothRewindEngine, found: ?DecodedFrame, cursor: u64, window: u64) bool {
        _ = self;
        const frame = found orelse return true;
        return frame.source == .checkpoint_picture and cursor -| frame.virtual_ns > window;
    }

    /// Exact position materialization on Pause.
    pub fn pause(self: *SmoothRewindEngine) !void {
        if (self.status != .playing_backward) {
            self.status = .paused;
            return;
        }

        const shown = self.current_frame orelse {
            self.status = .paused;
            return;
        };

        const target_pos = shown.position;
        try self.materialize(target_pos);
        self.status = .paused;
    }

    /// Materializes exact machine state at `target_pos`.
    /// 1. Uses ReverseWindow if it covers the position.
    /// 2. Otherwise restores nearest checkpoint and replays forward.
    pub fn materialize(self: *SmoothRewindEngine, target_pos: Position) !void {
        if (self.reverse_window) |win| {
            if (win.covers(target_pos)) {
                if (try self.walkWindowTo(win, target_pos)) {
                    return;
                }
            }
        }

        // Outside reverse window: checkpoint restore + silent forward replay.
        if (self.restore_hook) |hook| {
            try hook.restore(target_pos);
        }

        try self.replayForwardTo(target_pos);
    }

    fn walkWindowTo(self: *SmoothRewindEngine, win: *ReverseWindow, target_pos: Position) !bool {
        _ = self;
        if (win.end()) |end_pos| {
            if (std.meta.eql(end_pos, target_pos)) {
                try win.walkTo(win.count());
                return true;
            }
        }
        for (0..win.count()) |i| {
            const slot = win.slotAt(i);
            if (std.meta.eql(slot.pre, target_pos)) {
                try win.walkTo(i);
                return true;
            }
            if (std.meta.eql(slot.post, target_pos)) {
                try win.walkTo(i + 1);
                return true;
            }
        }
        return false;
    }

    fn replayForwardTo(self: *SmoothRewindEngine, target_pos: Position) !void {
        self.session.setReplaying(true);
        defer self.session.setReplaying(false);

        const core = self.session.currentCore();
        while (true) {
            const cur = self.session.currentPosition();
            const ord = self.session.comparePositions(cur, target_pos) catch break;
            if (ord != .lt) break;
            const ended = try self.session.run(core, .cont);
            if (ended != .count) break;
        }
    }
};

pub fn attachSmoothRewind(session: *api.Session, engine: *SmoothRewindEngine) void {
    session.smooth_rewind = engine;
}

pub fn startSmoothRewind(session: *api.Session, speed: f64) anyerror!void {
    const engine = session.smooth_rewind orelse return error.NoRewindEngine;
    try engine.start(speed);
}

pub fn tickSmoothRewind(session: *api.Session, dt_wall_ns: u64) anyerror!TickResult {
    const engine = session.smooth_rewind orelse return error.NoRewindEngine;
    return engine.tick(dt_wall_ns);
}

pub fn pauseSmoothRewind(session: *api.Session) anyerror!void {
    const engine = session.smooth_rewind orelse return error.NoRewindEngine;
    try engine.pause();
}

pub fn currentRewindFrame(session: *const api.Session) ?DecodedFrame {
    const engine = session.smooth_rewind orelse return null;
    return engine.current_frame;
}

pub fn setRewindSpeed(session: *api.Session, speed: f64) anyerror!void {
    const engine = session.smooth_rewind orelse return error.NoRewindEngine;
    engine.setSpeed(speed);
}
