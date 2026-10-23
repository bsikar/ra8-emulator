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
const frame_types = @import("frame_types.zig");
const frame_queue = @import("frame_queue.zig");

pub const Position = frame_types.Position;
pub const Glcdc = glcdc_mod.Glcdc;

pub const Clock = struct {
    context: *const anyopaque,
    nowNsFn: *const fn (context: *const anyopaque) i96,

    pub fn nowNs(self: Clock) i96 {
        return self.nowNsFn(self.context);
    }
};

fn ioNow(context: *const anyopaque) i96 {
    const io_ptr: *const std.Io = @ptrCast(@alignCast(context));
    return std.Io.Timestamp.now(io_ptr.*, .real).toNanoseconds();
}

pub fn clockFromIo(io_ptr: *const std.Io) Clock {
    return .{ .context = io_ptr, .nowNsFn = ioNow };
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
    spans: [2]?Span = .{ null, null },

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

    pub fn arm(self: *FrameTap, store: ?*Store) void {
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
            .io = std.testing.io,
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

    fn onBoundaryThunk(context: *anyopaque, virtual_ns: u64) void {
        const self: *FrameTap = @ptrCast(@alignCast(context));
        self.onBoundary(virtual_ns);
    }

    pub fn onBoundary(self: *FrameTap, virtual_ns: u64) void {
        const glcdc = &self.board.display;
        if (!self.isChanged(glcdc)) return;

        // Rate cap in host time
        const now_host = self.clock.nowNs();
        if (self.interval_ns > 0) {
            if (self.last_host_ns) |last| {
                if (now_host - last < self.interval_ns) return;
            }
        }

        self.capture(virtual_ns, glcdc) catch return;
        self.last_host_ns = now_host;
        self.captures_count += 1;
    }

    fn isChanged(self: *FrameTap, glcdc: *const Glcdc) bool {
        if (self.glcdc_dirty) return true;
        if (glcdc.writes != self.last_glcdc_writes) {
            self.updateSpans(glcdc);
            return true;
        }
        return self.memory_dirty;
    }

    fn updateSpans(self: *FrameTap, glcdc: *const Glcdc) void {
        self.last_glcdc_writes = glcdc.writes;
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

    fn capture(self: *FrameTap, virtual_ns: u64, glcdc: *const Glcdc) !void {
        const source = glcdc.compositeInputs() orelse return;
        self.glcdc_dirty = false;
        self.memory_dirty = false;
        self.updateSpans(glcdc);

        const memory = glcdc.memory orelse return;
        var total_bytes: usize = 0;
        for (source.planes[0..source.count]) |plane| {
            total_bytes += @as(usize, plane.shape.height) * plane.shape.stride;
        }

        var layer_bytes: ?[]u8 = null;
        if (total_bytes > 0) {
            const buf = try self.allocator.alloc(u8, total_bytes);
            var offset: usize = 0;
            for (source.planes[0..source.count]) |plane| {
                const len = @as(usize, plane.shape.height) * plane.shape.stride;
                memory.read(plane.shape.base, buf[offset .. offset + len]) catch {
                    self.allocator.free(buf);
                    return;
                };
                offset += len;
            }
            layer_bytes = buf;
        }

        const pos = Position{
            .branch = 0,
            .r = self.board.time.base.now() / 1_000_000,
            .phase = .board,
            .o = 0,
            .gap = .retired,
        };

        const is_key = (self.captures_count % 16 == 0);
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
