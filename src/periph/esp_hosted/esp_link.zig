//! The ESP32-C6 side of the esp-hosted SPI link, one frame at a time.
//!
//! Every transaction clocks one 1600-byte frame each way. The model keeps
//! the frame the host is sending, and when it ends parses it. A frame on
//! the private interface is the host announcing its capabilities; the
//! silicon answers that with its Event_ESPInit boot event and services no
//! RPC before it. The answer waits in the transmit queue and DATA_READY
//! stays high until the host clocks it out. With nothing queued the model
//! sends esp-hosted's idle filler. After the boot event, an RPC request on
//! the serial interface gets its answer queued the same way.
const frame = @import("esp_frame.zig");
const event = @import("esp_event.zig");
const rpc = @import("esp_rpc.zig");

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
    reply: [frame.frame_size]u8 = undefined,
    reply_queued: bool = false,
    replies_sent: u32 = 0,

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
        return self.boot_queued or self.reply_queued;
    }

    fn load(self: *Link) void {
        if (self.boot_queued) {
            self.boot_queued = false;
            if (event.espInitFrame(&self.tx, 0)) |_| {
                self.boots_sent += 1;
                return;
            } else |_| {}
        }
        if (self.reply_queued) {
            self.reply_queued = false;
            @memcpy(&self.tx, &self.reply);
            self.replies_sent += 1;
            return;
        }
        frame.filler(&self.tx);
    }

    fn receive(self: *Link) void {
        const got = frame.parse(&self.rx) catch return;
        if (got.header.interface == .priv) self.announce(got.payload);
        if (got.header.interface == .serial) self.serve(got.payload);
    }

    fn announce(self: *Link, payload: []const u8) void {
        self.caps_seen = true;
        const take = @min(payload.len, caps_capacity);
        @memcpy(self.caps[0..take], payload[0..take]);
        self.caps_len = @intCast(take);
        self.boot_queued = true;
    }

    /// Answers a known RPC request; none before the host has announced itself.
    fn serve(self: *Link, payload: []const u8) void {
        if (!self.caps_seen or self.reply_queued) return;
        const proto = rpc.tlvData(payload) orelse return;
        const req = rpc.request(proto) catch return;
        self.reply_queued = rpc.answerFrame(&self.reply, req) catch false;
    }
};
