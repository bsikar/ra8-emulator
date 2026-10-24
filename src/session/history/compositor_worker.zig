//! Compositor worker: drains tasks from the frame queue, runs pure composition
//! over private value copies, converts to grayscale, and produces compressed
//! keyframe and delta crop records for the frame sink (milestone M7).
//!
//! Operates strictly on value copies; never touches the guest or session.
const std = @import("std");
const glcdc_mod = @import("ra8_chip").periph.glcdc;
const mix = glcdc_mod.mix;
const Store = @import("ra8_chip").core.cpu.memory.store.Store;
const Guest = @import("ra8_chip").core.cpu.memory.guest.Guest;
const frame_types = @import("frame_types.zig");
const frame_crop = @import("frame_crop.zig");
const frame_queue = @import("frame_queue.zig");

pub const Task = frame_queue.Task;
pub const Queue = frame_queue.Queue;
pub const FrameRecord = frame_types.FrameRecord;
pub const FrameSink = frame_types.FrameSink;
pub const Rect = frame_types.Rect;

const PlaneReader = struct {
    planes: [2]PlaneMapping = undefined,
    count: usize = 0,

    const PlaneMapping = struct {
        base: u32,
        len: usize,
        data: []const u8,
    };

    fn read(ctx: *anyopaque, address: u32, into: []u8) error{Unmapped}!void {
        const self: *const PlaneReader = @ptrCast(@alignCast(ctx));
        for (self.planes[0..self.count]) |m| {
            if (address >= m.base and @as(u64, address) + into.len <= @as(u64, m.base) + m.len) {
                const off = address - m.base;
                @memcpy(into, m.data[off .. off + into.len]);
                return;
            }
        }
        return error.Unmapped;
    }
};

pub const CompositorWorker = struct {
    allocator: std.mem.Allocator,
    queue: *Queue,
    sink: ?FrameSink = null,
    current_epoch: u64 = 0,

    dummy_store: Store = .{},
    scratch_argb: std.ArrayListUnmanaged(u32) = .empty,
    scratch_gray: std.ArrayListUnmanaged(u8) = .empty,

    keyframe_gray: std.ArrayListUnmanaged(u8) = .empty,
    keyframe_width: u32 = 0,
    keyframe_height: u32 = 0,

    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: std.mem.Allocator, queue: *Queue, sink: ?FrameSink) CompositorWorker {
        return .{
            .allocator = allocator,
            .queue = queue,
            .sink = sink,
        };
    }

    pub fn deinit(self: *CompositorWorker) void {
        self.stop();
        self.scratch_argb.deinit(self.allocator);
        self.scratch_gray.deinit(self.allocator);
        self.keyframe_gray.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn start(self: *CompositorWorker) !void {
        if (self.running.load(.acquire)) return;
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, threadEntry, .{self});
    }

    pub fn stop(self: *CompositorWorker) void {
        if (!self.running.swap(false, .acq_rel)) return;
        self.queue.close();
        if (self.thread) |th| {
            th.join();
            self.thread = null;
        }
    }

    fn threadEntry(self: *CompositorWorker) void {
        while (self.queue.pop()) |task| {
            var t = task;
            defer t.deinit(self.allocator);
            self.processTask(&t) catch {};
        }
    }

    /// Process one task if available without blocking. Returns true if a task was processed.
    pub fn step(self: *CompositorWorker) !bool {
        var task = self.queue.tryPop() orelse return false;
        defer task.deinit(self.allocator);
        try self.processTask(&task);
        return true;
    }

    /// Synchronously process all currently queued tasks until queue is empty.
    pub fn drain(self: *CompositorWorker) !usize {
        var count: usize = 0;
        while (try self.step()) {
            count += 1;
        }
        return count;
    }

    fn processTask(self: *CompositorWorker, task: *Task) !void {
        if (task.epoch < self.current_epoch) return;

        if (task.kind == .regenerate_by_replay) {
            try self.emitRegenerate(task);
            return;
        }

        try self.renderTask(task);
    }

    fn emitRegenerate(self: *CompositorWorker, task: *const Task) !void {
        self.keyframe_gray.clearRetainingCapacity();
        self.keyframe_width = 0;
        self.keyframe_height = 0;

        var record = FrameRecord{
            .header = .{
                .magic = frame_types.magic,
                .version = frame_types.version,
                .kind = .regenerate_by_replay,
                .position = task.position,
                .virtual_ns = task.virtual_ns,
                .width = @intCast(task.width),
                .height = @intCast(task.height),
                .rect = .{ .x = 0, .y = 0, .width = @intCast(task.width), .height = @intCast(task.height) },
                .uncompressed_len = 0,
                .compressed_len = 0,
                .crc32c = 0,
            },
            .payload = &.{},
        };
        defer record.deinit(self.allocator);

        if (self.sink) |s| try s.writeFrame(&record);
    }

    fn renderTask(self: *CompositorWorker, task: *const Task) !void {
        const pixel_count = @as(usize, task.width) * task.height;
        if (pixel_count == 0) return;

        try self.scratch_argb.resize(self.allocator, pixel_count);
        try self.scratch_gray.resize(self.allocator, pixel_count);

        var source = task.source;
        var reader = PlaneReader{};
        if (task.layer_bytes) |bytes| {
            var offset: usize = 0;
            for (source.planes[0..source.count]) |plane| {
                const len = @as(usize, plane.shape.height) * plane.shape.stride;
                if (offset + len <= bytes.len) {
                    reader.planes[reader.count] = .{
                        .base = plane.shape.base,
                        .len = len,
                        .data = bytes[offset .. offset + len],
                    };
                    reader.count += 1;
                }
                offset += len;
            }
            source.memory = Guest{
                .store = &self.dummy_store,
                .read_fn = PlaneReader.read,
                .read_ctx = &reader,
            };
        } else {
            source.memory = Guest{ .store = &self.dummy_store };
        }

        const res = glcdc_mod.pure.composite(&task.glcdc, source, task.powered, self.scratch_argb.items);
        switch (res) {
            .picture => {},
            .refused => return,
        }

        frame_crop.toGray(self.scratch_argb.items, self.scratch_gray.items);

        const is_key = (task.kind == .keyframe or
            self.keyframe_gray.items.len != pixel_count or
            self.keyframe_width != task.width or
            self.keyframe_height != task.height);

        if (is_key) {
            try self.emitKeyframe(task, pixel_count);
        } else {
            try self.emitDelta(task);
        }
    }

    fn emitKeyframe(self: *CompositorWorker, task: *const Task, pixel_count: usize) !void {
        try self.keyframe_gray.resize(self.allocator, pixel_count);
        @memcpy(self.keyframe_gray.items, self.scratch_gray.items);
        self.keyframe_width = task.width;
        self.keyframe_height = task.height;

        const compressed = try frame_crop.compress(self.allocator, self.scratch_gray.items);
        var record = FrameRecord{
            .header = .{
                .magic = frame_types.magic,
                .version = frame_types.version,
                .kind = .keyframe,
                .position = task.position,
                .virtual_ns = task.virtual_ns,
                .width = @intCast(task.width),
                .height = @intCast(task.height),
                .rect = .{ .x = 0, .y = 0, .width = @intCast(task.width), .height = @intCast(task.height) },
                .uncompressed_len = @intCast(pixel_count),
                .compressed_len = @intCast(compressed.len),
                .crc32c = frame_types.FrameHeader.computeCrc(compressed),
            },
            .payload = compressed,
        };
        defer record.deinit(self.allocator);

        if (self.sink) |s| try s.writeFrame(&record);
    }

    fn emitDelta(self: *CompositorWorker, task: *const Task) !void {
        const maybe_diff = frame_crop.diffBox(self.keyframe_gray.items, self.scratch_gray.items, task.width);
        const rect = maybe_diff orelse Rect{ .x = 0, .y = 0, .width = 0, .height = 0 };

        var compressed: []const u8 = &.{};
        if (rect.width > 0 and rect.height > 0) {
            const crop_len = @as(usize, rect.width) * rect.height;
            const crop_buf = try self.allocator.alloc(u8, crop_len);
            defer self.allocator.free(crop_buf);
            frame_crop.extractCrop(self.scratch_gray.items, task.width, rect, crop_buf);
            compressed = try frame_crop.compress(self.allocator, crop_buf);
        }

        var record = FrameRecord{
            .header = .{
                .magic = frame_types.magic,
                .version = frame_types.version,
                .kind = .delta,
                .position = task.position,
                .virtual_ns = task.virtual_ns,
                .width = @intCast(task.width),
                .height = @intCast(task.height),
                .rect = rect,
                .uncompressed_len = @as(u32, rect.width) * rect.height,
                .compressed_len = @intCast(compressed.len),
                .crc32c = if (compressed.len > 0) frame_types.FrameHeader.computeCrc(compressed) else 0,
            },
            .payload = compressed,
        };
        defer record.deinit(self.allocator);

        if (self.sink) |s| try s.writeFrame(&record);
    }
};
