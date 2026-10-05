//! The board as the UI thread sees it, handed over through the triple
//! buffer (RA8EMU-227). The emulator side copies the scanned panel and the
//! LEDs into its back slot and publishes; the window reads the newest
//! published slot as a host_loop.Board without ever touching the board
//! the engine is running. Each slot owns its pixels and only the writer
//! resizes the slot it holds, so a resized panel never races the reader.
const std = @import("std");
const host_loop = @import("host_loop.zig");
const TripleBuffer = @import("triple_buffer.zig").TripleBuffer;

pub const Led = std.meta.Child(@FieldType(host_loop.Board, "leds"));
pub const max_leds = 8;

pub const Snapshot = struct {
    pixels: []u32 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    leds: [max_leds]Led = undefined,
    led_count: usize = 0,

    /// What one handoff carries, for the per-frame size log.
    pub fn bytes(self: *const Snapshot) usize {
        return self.pixels.len * @sizeOf(u32) + self.led_count * @sizeOf(Led);
    }

    pub fn board(self: *const Snapshot) host_loop.Board {
        return .{ .panel = self.pixels, .width = self.width, .height = self.height, .leds = self.leds[0..self.led_count] };
    }
};

pub const Handoff = struct {
    allocator: std.mem.Allocator,
    buffer: TripleBuffer(Snapshot) = .init(.{}),
    /// Bytes the last publish carried.
    last_bytes: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Handoff {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Handoff) void {
        for (&self.buffer.slots) |*slot| self.allocator.free(slot.pixels);
    }

    /// Emulator side: copy `view` into the back slot and publish it.
    pub fn publish(self: *Handoff, view: host_loop.Board) error{ OutOfMemory, TooManyLeds }!usize {
        if (view.leds.len > max_leds) return error.TooManyLeds;
        const slot = self.buffer.writeSlot();
        if (slot.pixels.len != view.panel.len) {
            self.allocator.free(slot.pixels);
            slot.pixels = &.{};
            slot.pixels = try self.allocator.alloc(u32, view.panel.len);
        }
        @memcpy(slot.pixels, view.panel);
        slot.width = view.width;
        slot.height = view.height;
        @memcpy(slot.leds[0..view.leds.len], view.leds);
        slot.led_count = view.leds.len;
        self.buffer.publish();
        self.last_bytes = slot.bytes();
        return self.last_bytes;
    }

    /// UI side: the newest board when one arrived since the last call.
    pub fn latest(self: *Handoff) ?host_loop.Board {
        const snap = self.buffer.latest() orelse return null;
        return snap.board();
    }

    /// UI side: the board it holds now, fresh or not.
    pub fn current(self: *const Handoff) host_loop.Board {
        return self.buffer.current().board();
    }
};
