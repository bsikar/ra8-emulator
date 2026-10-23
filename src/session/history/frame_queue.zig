//! Bounded 64 MiB FIFO task queue for frame composition and capture (milestone M7).
//!
//! Enforces a hard capacity bound (64 MiB). When the queue is full, incoming
//! frames are not dropped silently; instead, their payload is discarded and the
//! frame is enqueued with kind .regenerate_by_replay to record that replay must
//! synthesize this frame when requested.
const std = @import("std");
const glcdc_mod = @import("ra8_chip").periph.glcdc;
const frame_types = @import("frame_types.zig");

pub const Position = frame_types.Position;
pub const FrameKind = frame_types.FrameKind;
pub const Glcdc = glcdc_mod.Glcdc;
pub const Source = glcdc_mod.mix.Source;

pub const default_capacity: usize = 64 * 1024 * 1024; // 64 MiB

pub const Task = struct {
    kind: FrameKind,
    position: Position,
    virtual_ns: u64,
    width: u16,
    height: u16,
    epoch: u64 = 0,
    glcdc: Glcdc = undefined,
    source: Source = undefined,
    powered: bool = false,
    layer_bytes: ?[]u8 = null,
    bytes_cost: usize = 0,

    pub fn deinit(self: *Task, allocator: std.mem.Allocator) void {
        if (self.layer_bytes) |bytes| {
            allocator.free(bytes);
            self.layer_bytes = null;
        }
    }
};

const SpinLock = struct {
    state: std.atomic.Value(bool) = .init(false),

    fn lock(self: *SpinLock) void {
        while (self.state.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
            std.Thread.yield() catch {};
        }
    }

    fn unlock(self: *SpinLock) void {
        self.state.store(false, .release);
    }
};

pub const Queue = struct {
    allocator: std.mem.Allocator,
    capacity_bytes: usize,
    used_bytes: usize = 0,
    overflow_count: u64 = 0,
    tasks: std.ArrayListUnmanaged(Task) = .empty,
    head: usize = 0,
    lock: SpinLock = .{},
    closed: bool = false,

    pub fn init(allocator: std.mem.Allocator, cap_bytes: usize) Queue {
        return .{
            .allocator = allocator,
            .capacity_bytes = cap_bytes,
        };
    }

    pub fn deinit(self: *Queue) void {
        self.lock.lock();
        defer self.lock.unlock();
        for (self.tasks.items[self.head..]) |*task| {
            task.deinit(self.allocator);
        }
        self.tasks.deinit(self.allocator);
        self.* = undefined;
    }

    /// Push a task into the queue. If adding the task exceeds capacity,
    /// marks the task as regenerate_by_replay, drops the pixel payload,
    /// and enqueues the marker without silent drop.
    pub fn push(self: *Queue, task: Task) !void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.closed) return error.Closed;

        var to_enqueue = task;
        if (self.used_bytes + to_enqueue.bytes_cost > self.capacity_bytes) {
            // Queue full: discard pixel payload and mark regenerate_by_replay
            if (to_enqueue.layer_bytes) |bytes| {
                self.allocator.free(bytes);
                to_enqueue.layer_bytes = null;
            }
            to_enqueue.kind = .regenerate_by_replay;
            to_enqueue.bytes_cost = 0;
            self.overflow_count += 1;
        }

        try self.tasks.append(self.allocator, to_enqueue);
        self.used_bytes += to_enqueue.bytes_cost;
    }

    /// Non-blocking pop. Returns null if empty.
    pub fn tryPop(self: *Queue) ?Task {
        self.lock.lock();
        defer self.lock.unlock();
        return self.popLocked();
    }

    /// Blocking pop. Waits until a task is available or queue is closed.
    pub fn pop(self: *Queue) ?Task {
        while (true) {
            self.lock.lock();
            if (self.popLocked()) |task| {
                self.lock.unlock();
                return task;
            }
            if (self.closed) {
                self.lock.unlock();
                return null;
            }
            self.lock.unlock();
            std.atomic.spinLoopHint();
            std.Thread.yield() catch {};
        }
    }

    fn popLocked(self: *Queue) ?Task {
        if (self.head >= self.tasks.items.len) return null;
        const task = self.tasks.items[self.head];
        self.head += 1;
        self.used_bytes -|= task.bytes_cost;
        if (self.head > 64 and self.head * 2 >= self.tasks.items.len) {
            const remaining = self.tasks.items.len - self.head;
            std.mem.copyForwards(Task, self.tasks.items[0..remaining], self.tasks.items[self.head..]);
            self.tasks.items.len = remaining;
            self.head = 0;
        }
        return task;
    }

    pub fn close(self: *Queue) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.closed = true;
    }

    pub fn count(self: *Queue) usize {
        self.lock.lock();
        defer self.lock.unlock();
        return self.tasks.items.len - self.head;
    }

    pub fn bytesUsed(self: *Queue) usize {
        self.lock.lock();
        defer self.lock.unlock();
        return self.used_bytes;
    }

    pub fn overflows(self: *Queue) u64 {
        self.lock.lock();
        defer self.lock.unlock();
        return self.overflow_count;
    }
};
