//! The ESP32-C6 side of the esp-hosted SPI link, one frame at a time.
//!
//! Every transaction clocks one 1600-byte frame each way. The model keeps
//! the frame the host is sending, and when it ends parses it. A frame on
//! the private interface is the host announcing its capabilities; the
//! silicon answers that with its Event_ESPInit boot event and services no
//! RPC before it. The answer waits in the transmit queue and DATA_READY
//! stays high until the host clocks it out. With nothing queued the model
//! sends esp-hosted's idle filler.
const frame = @import("esp_frame.zig");
const event = @import("esp_event.zig");

/// Octets of the host capabilities announcement kept for inspection.
pub const caps_capacity: usize = 17;

pub const Link = struct {
    rx: [frame.frame_size]u8 = undefined,
    tx: [frame.frame_size]u8 = undefined,
    offset: u16 = 0,
    caps_seen: bool = false,
    caps: [caps_capacity]u8 = .{0} ** caps_capacity,
    caps_len: u8 = 0,
    boot_queued: bool = false,
    boots_sent: u32 = 0,

    /// Clocks one byte in from the host and returns the byte clocked out.
    pub fn exchange(self: *Link, byte: u8) u8 {
        if (self.offset == 0) self.load();
        const out = self.tx[self.offset];
        self.rx[self.offset] = byte;
        self.offset += 1;
        if (self.offset == frame.frame_size) {
            self.offset = 0;
            self.receive();
        }
        return out;
    }

    /// DATA_READY: high while the transmit queue holds a frame.
    pub fn dataReady(self: *const Link) bool {
        return self.boot_queued;
    }

    fn load(self: *Link) void {
        if (self.boot_queued) {
            self.boot_queued = false;
            if (event.espInitFrame(&self.tx, 0)) |_| {
                self.boots_sent += 1;
                return;
            } else |_| {}
        }
        frame.filler(&self.tx);
    }

    fn receive(self: *Link) void {
        const got = frame.parse(&self.rx) catch return;
        if (got.header.interface != .priv) return;
        self.caps_seen = true;
        const take = @min(got.payload.len, caps_capacity);
        @memcpy(self.caps[0..take], got.payload[0..take]);
        self.caps_len = @intCast(take);
        self.boot_queued = true;
    }
};
