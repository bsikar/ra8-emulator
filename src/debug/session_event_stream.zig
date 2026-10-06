//! Bounded per-subscriber queues for session events (RA8EMU-192).
const std = @import("std");

pub const Core = enum(u8) { cpu0, cpu1 };
pub const Event = struct {
    core: Core,
    virtual_ns: u64 = 0,
    kind: Kind,
    address: ?u32 = null,
    ended: ?@import("zig_drive.zig").Ended = null,
    payload: Payload = .none,
    pub const Kind = enum { loaded, paused, stopped, register_written, memory_written, breakpoint_set, breakpoint_cleared, watchpoint_set, watchpoint_cleared, speed_changed, input_scheduled, fault_set, fault_cleared, plugged, unplugged, uart_byte, gpio_changed, led_changed, lcd_frame, fault, reset, watchdog };
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
    };
};
pub const capacity = 128;
pub const subscribers = 8;
pub const Read = struct { count: usize, dropped: u64 };
const Queue = struct {
    items: [capacity]Event = undefined,
    head: usize = 0,
    len: usize = 0,
    dropped: u64 = 0,
    fn push(self: *Queue, event: Event) void {
        if (event.kind == .lcd_frame) {
            for (0..self.len) |i| {
                const at = (self.head + i) % capacity;
                if (self.items[at].kind == .lcd_frame and self.items[at].core == event.core) {
                    self.items[at] = event;
                    self.dropped += 1;
                    return;
                }
            }
        }
        if (self.len == capacity) {
            self.head = (self.head + 1) % capacity;
            self.len -= 1;
            self.dropped += 1;
        }
        self.items[(self.head + self.len) % capacity] = event;
        self.len += 1;
    }
    fn read(self: *Queue, out: []Event) Read {
        const count = @min(self.len, out.len);
        for (0..count) |i| out[i] = self.items[(self.head + i) % capacity];
        self.head = (self.head + count) % capacity;
        self.len -= count;
        const dropped = self.dropped;
        self.dropped = 0;
        return .{ .count = count, .dropped = dropped };
    }
};
pub const Stream = struct {
    queues: [subscribers]?Queue = [_]?Queue{null} ** subscribers,
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
};
