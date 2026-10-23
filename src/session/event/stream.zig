//! Bounded per-subscriber queues for timestamped session events (RA8EMU-192).
//!
//! Subscribe and unsubscribe while the engine is stopped, then poll from a
//! consumer thread. Producers never wait for a consumer: an event is reported
//! as dropped if polling owns the queue, queued LCD frames coalesce per core,
//! and a full queue discards its oldest telemetry first (RA8EMU-1179): those
//! kinds are lossy. State-change kinds are dropped only when the queue holds
//! no telemetry, and events preserve publication order.
const std = @import("std");

pub const Core = enum(u8) { cpu0, cpu1 };
pub const Event = struct {
    core: Core,
    virtual_ns: u64 = 0,
    kind: Kind,
    address: ?u32 = null,
    ended: ?@import("../zig/drive.zig").Ended = null,
    payload: Payload = .none,
    pub const Kind = enum { loaded, paused, stopped, rewound, register_written, memory_written, breakpoint_set, breakpoint_cleared, watchpoint_set, watchpoint_cleared, speed_changed, input_scheduled, fault_set, fault_cleared, plugged, unplugged, uart_byte, gpio_changed, led_changed, lcd_frame, fault, reset, watchdog, rtos_switch, rtos_idle, isr_enter, isr_leave, module_loaded, module_unloaded, module_faulted, bkpt_skipped, console_input, camera_changed };

    pub const Rect = struct { x: u16, y: u16, width: u16, height: u16 };
    pub const Payload = union(enum) {
        none,
        uart: struct { channel: u8, byte: u8 },
        gpio: struct { port: u8, changed: u16, levels: u16 },
        led: struct { index: u8, level: bool },
        frame: struct { width: u32, height: u32, generation: u64, dirty: Rect },
        fault: struct { cause: u32, address: ?u32 = null },
        reset: enum { software, watchdog, iwdt },
        watchdog: enum { wdt, iwdt },
        rtos: struct { thread: u32 = 0, exception: u16 = 0 },
    };
};
/// A full queue evicts telemetry kinds first (RA8EMU-1179).
fn telemetry(kind: Event.Kind) bool {
    return switch (kind) {
        .uart_byte, .gpio_changed, .led_changed, .lcd_frame, .fault, .reset, .watchdog, .rtos_switch, .rtos_idle, .isr_enter, .isr_leave, .module_loaded, .module_unloaded, .module_faulted => true,
        else => false,
    };
}

pub const capacity = 128;
pub const subscribers = 8;
pub const Read = struct { count: usize, dropped: u64 };
const Queue = struct {
    items: [capacity]Event = undefined,
    mutex: std.atomic.Mutex = .unlocked,
    dropped: std.atomic.Value(u64) = .init(0),
    head: usize = 0,
    len: usize = 0,
    fn push(self: *Queue, event: Event) void {
        if (!self.mutex.tryLock()) {
            _ = self.dropped.fetchAdd(1, .monotonic);
            return;
        }
        defer self.mutex.unlock();
        if (event.kind == .lcd_frame) {
            for (0..self.len) |i| {
                const at = (self.head + i) % capacity;
                if (self.items[at].kind != .lcd_frame or self.items[at].core != event.core) continue;
                self.removeAt(i);
                break;
            }
        }
        if (self.len == capacity) self.removeAt(self.oldestTelemetry() orelse 0);
        self.items[(self.head + self.len) % capacity] = event;
        self.len += 1;
    }

    /// Telemetry kinds are lossy: a full queue may evict them. The rest are
    /// state changes the client must see to stay in sync (RA8EMU-1179).
    fn oldestTelemetry(self: *Queue) ?usize {
        for (0..self.len) |i| {
            if (telemetry(self.items[(self.head + i) % capacity].kind)) return i;
        }
        return null;
    }

    /// Drop the entry at the offset from the head, close the gap, count it.
    fn removeAt(self: *Queue, at: usize) void {
        self.len -= 1;
        if (at == 0) {
            self.head = (self.head + 1) % capacity;
        } else {
            for (at..self.len) |move| {
                self.items[(self.head + move) % capacity] = self.items[(self.head + move + 1) % capacity];
            }
        }
        _ = self.dropped.fetchAdd(1, .monotonic);
    }
    fn read(self: *Queue, out: []Event) Read {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        const count = @min(self.len, out.len);
        for (0..count) |i| out[i] = self.items[(self.head + i) % capacity];
        self.head = (self.head + count) % capacity;
        self.len -= count;
        return .{ .count = count, .dropped = self.dropped.swap(0, .monotonic) };
    }
};
pub const Stream = struct {
    queues: [subscribers]?Queue = @splat(null),
    pub fn subscribe(self: *Stream) ?usize {
        for (&self.queues, 0..) |*slot, id| {
            if (slot.* != null) continue;
            slot.* = .{};
            return id;
        }
        return null;
    }
    pub fn unsubscribe(self: *Stream, id: usize) void {
        if (id < self.queues.len) self.queues[id] = null;
    }
    pub fn publish(self: *Stream, event: Event) void {
        for (&self.queues) |*slot| if (slot.*) |*queue| queue.push(event);
    }
    pub fn read(self: *Stream, id: usize, out: []Event) ?Read {
        if (id >= self.queues.len) return null;
        if (self.queues[id]) |*queue| return queue.read(out);
        return null;
    }

    /// Whether any subscriber queue holds half its capacity or more: the
    /// owner should drain before telemetry starts losing to eviction
    /// (RA8EMU-1179).
    pub fn nearFull(self: *Stream) bool {
        for (&self.queues) |*slot| if (slot.*) |*queue| {
            while (!queue.mutex.tryLock()) std.atomic.spinLoopHint();
            defer queue.mutex.unlock();
            if (queue.len * 2 >= capacity) return true;
        };
        return false;
    }
};
