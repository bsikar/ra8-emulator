//! The passive, change-triggered frame tap (milestone M7).
//!
//! Captures frames once per boundary after the board tick, never a grid edge,
//! never arms vsync, and never mutates guest-visible state. Change-triggered
//! by write observer hits on active fetching layer spans or GLCDC register writes.
//! Rate-capped to at most one copy per 1/60 s host time via injected clock.
const std = @import("std");
const Board = @import("ra8_board").board.Board;
const board_tap = @import("ra8_board").frame_tap;
const glcdc_mod = @import("ra8_chip").periph.glcdc;
const observer = @import("ra8_chip").core.cpu.memory.observer;
const Store = @import("ra8_chip").core.cpu.memory.store.Store;
const scheduler = @import("ra8_chip").core.scheduler;
const frame_types = @import("frame_types.zig");
const frame_queue = @import("frame_queue.zig");

pub const Position = frame_types.Position;
pub const Glcdc = glcdc_mod.Glcdc;

pub const Clock = struct {
    io: ?std.Io = null,
    context: ?*const anyopaque = null,
    nowNsFn: ?*const fn (context: *const anyopaque) i96 = null,

    pub fn fromIo(io: std.Io) Clock {
        return .{ .io = io };
    }

    pub fn custom(context: *const anyopaque, nowNsFn: *const fn (context: *const anyopaque) i96) Clock {
        return .{ .context = context, .nowNsFn = nowNsFn };
    }

    pub fn nowNs(self: Clock) i96 {
        if (self.io) |io| {
            return std.Io.Timestamp.now(io, .real).toNanoseconds();
        }
        if (self.nowNsFn) |f| {
            return f(self.context.?);
        }
        return 0;
    }
};

pub fn clockFromIo(io: std.Io) Clock {
    return Clock.fromIo(io);
}

pub const Span = struct {
    base: u32,
    size: u32,

    pub fn contains(self: Span, addr: u64, len: usize) bool {
        const start = @as(u64, self.base);
        const end = start + self.size;
        return addr < end and (addr + len) > start;
    }
};

pub const FrameTap = struct {
    allocator: std.mem.Allocator,
    board: *Board,
    queue: *frame_queue.Queue,
    clock: Clock,
    interval_ns: i96 = 16_666_667, // 1/60 s (60 Hz)
    last_host_ns: ?i96 = null,
    epoch: u64 = 0,

    last_glcdc_writes: u32 = 0,
    glcdc_dirty: bool = true,
    memory_dirty: bool = true,
    force_keyframe: bool = true,
    spans: [2]?Span = .{ null, null },

    grid: ?*const scheduler.State = null,
    branch: u32 = 0,

    attached_store: ?*Store = null,
    prev_observer: ?*const observer.Observer = null,
    tap_observer: observer.Observer = undefined,
    board_tap_hook: board_tap.Tap = undefined,
    captures_count: u64 = 0,

    const observer_vtable = observer.Observer.VTable{
        .bytes = onBytes,
        .barrier = onBarrier,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        board: *Board,
        queue: *frame_queue.Queue,
        clock: Clock,
    ) FrameTap {
        return .{
            .allocator = allocator,
            .board = board,
            .queue = queue,
            .clock = clock,
        };
    }

    pub fn deinit(self: *FrameTap) void {
        self.disarm();
    }

    pub fn arm(self: *FrameTap, io: std.Io, store: ?*Store) void {
        self.tap_observer = .{
            .ctx = self,
            .vtable = &observer_vtable,
        };
        if (store) |s| {
            self.attached_store = s;
            self.prev_observer = s.observer;
            s.observer = &self.tap_observer;
        }
        self.glcdc_dirty = true;
        self.memory_dirty = true;
        self.board_tap_hook = .{
            .io = io,
            .context = self,
            .captureFn = onBoundaryThunk,
            .interval_ns = 0,
        };
        self.board.frame_tap = &self.board_tap_hook;
    }

    pub fn disarm(self: *FrameTap) void {
        if (self.attached_store) |s| {
            if (s.observer == &self.tap_observer) {
                s.observer = self.prev_observer;
            }
            self.attached_store = null;
            self.prev_observer = null;
        }
        if (self.board.frame_tap == &self.board_tap_hook) {
            self.board.frame_tap = null;
        }
    }

    pub fn setPositionSource(self: *FrameTap, grid: ?*const scheduler.State, branch: u32) void {
        self.grid = grid;
        self.branch = branch;
    }

    pub fn forceKeyframe(self: *FrameTap) void {
        self.force_keyframe = true;
    }

    pub fn newSegment(self: *FrameTap) void {
        self.force_keyframe = true;
    }

    fn onBoundaryThunk(context: *anyopaque, virtual_ns: u64) void {
        const self: *FrameTap = @ptrCast(@alignCast(context));
        self.onBoundary(virtual_ns);
    }

    pub fn onBoundary(self: *FrameTap, virtual_ns: u64) void {
        self.onBoundaryWithPosition(virtual_ns, null);
    }

    pub fn onBoundaryWithPosition(self: *FrameTap, virtual_ns: u64, maybe_pos: ?Position) void {
        const glcdc = &self.board.display;
        if (!self.isChanged(glcdc)) return;

        // Rate cap in host time
        const now_host = self.clock.nowNs();
        if (self.interval_ns > 0) {
            if (self.last_host_ns) |last| {
                if (now_host - last < self.interval_ns) return;
            }
        }

        self.capture(virtual_ns, glcdc, maybe_pos) catch return;
        self.last_host_ns = now_host;
        self.captures_count += 1;
    }

    fn isChanged(self: *const FrameTap, glcdc: *const Glcdc) bool {
        if (self.glcdc_dirty) return true;
        if (glcdc.writes != self.last_glcdc_writes) return true;
        return self.memory_dirty;
    }

    fn updateSpans(self: *FrameTap, glcdc: *const Glcdc) void {
        for (1..3) |layer| {
            if (glcdc.decode(@intCast(layer))) |fb| {
                self.spans[layer - 1] = .{
                    .base = fb.base,
                    .size = fb.height * fb.stride,
                };
            } else {
                self.spans[layer - 1] = null;
            }
        }
    }

    fn capture(self: *FrameTap, virtual_ns: u64, glcdc: *const Glcdc, explicit_pos: ?Position) !void {
        const source = glcdc.compositeInputs() orelse return;
        const memory = glcdc.memory orelse return;

        var total_bytes: usize = 0;
        for (source.planes[0..source.count]) |plane| {
            total_bytes += @as(usize, plane.shape.height) * plane.shape.stride;
        }

        var layer_bytes: ?[]u8 = null;
        if (total_bytes > 0) {
            const buf = try self.allocator.alloc(u8, total_bytes);
            errdefer self.allocator.free(buf);
            var offset: usize = 0;
            for (source.planes[0..source.count]) |plane| {
                const len = @as(usize, plane.shape.height) * plane.shape.stride;
                try memory.read(plane.shape.base, buf[offset .. offset + len]);
                offset += len;
            }
            layer_bytes = buf;
        }

        const pos = explicit_pos orelse if (self.grid) |g| blk: {
            var p = g.at;
            p.branch = self.branch;
            break :blk p;
        } else Position{
            .branch = self.branch,
            .r = 0,
            .phase = .board,
            .o = 0,
            .gap = .retired,
        };

        const is_key = self.force_keyframe or (self.captures_count == 0);
        const task = frame_queue.Task{
            .kind = if (is_key) .keyframe else .delta,
            .position = pos,
            .virtual_ns = virtual_ns,
            .width = @intCast(source.width),
            .height = @intCast(source.height),
            .epoch = self.epoch,
            .glcdc = glcdc.*,
            .source = source,
            .powered = self.board.display.domain.powered(),
            .layer_bytes = layer_bytes,
            .bytes_cost = total_bytes,
        };

        try self.queue.push(task);
        self.force_keyframe = false;
        self.glcdc_dirty = false;
        self.memory_dirty = false;
        self.last_glcdc_writes = glcdc.writes;
        self.updateSpans(glcdc);
    }

    fn onBytes(ctx: *anyopaque, write: observer.Write) void {
        const self: *FrameTap = @ptrCast(@alignCast(ctx));
        if (self.prev_observer) |prev| prev.bytes(write);

        if (self.memory_dirty) return;
        const target = @as(u64, write.base) + write.offset;
        for (self.spans) |maybe_span| {
            if (maybe_span) |span| {
                if (span.contains(target, write.pre.len)) {
                    self.memory_dirty = true;
                    return;
                }
            }
        }
    }

    fn onBarrier(ctx: *anyopaque, event: observer.Barrier) void {
        const self: *FrameTap = @ptrCast(@alignCast(ctx));
        if (self.prev_observer) |prev| prev.barrier(event);
        self.memory_dirty = true;
    }
};
