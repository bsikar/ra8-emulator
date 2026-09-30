//! What the card puts on the line: the bytes an SD card answers with in SPI
//! mode, and the reply the host is part way through clocking out of it.
//!
//! Its own file because it is the card's whole outgoing side and none of it
//! is protocol decisions: sd_card.zig decides what to answer, this holds the
//! answer and hands it over one byte per exchange, which is the only rate the
//! wire has.
const image = @import("sd_image.zig");
const sd_crc = @import("sd_crc.zig");

/// The bytes the card drives. Idle is a line nobody is holding low.
pub const token = struct {
    pub const idle: u8 = 0xFF;
    pub const busy: u8 = 0x00;
    /// Data-start, ahead of a block the card hands out.
    pub const data: u8 = 0xFE;
    /// Data response: the block was taken.
    pub const accepted: u8 = 0x05;
    /// Data response: the block's checksum did not match. dev's header names
    /// the accept and write-error codes; this is the SD data-response CRC
    /// code, named here because no header in this tree gives it.
    pub const crc_error: u8 = 0x0B;
    /// Data response: the card could not store the block.
    pub const write_error: u8 = 0x0D;
    /// Read data-error, out of range. Named here for the same reason.
    pub const read_error: u8 = 0x08;
};

/// R1, as far as this model sets it.
pub const r1 = struct {
    pub const ready: u8 = 0x00;
    pub const idle: u8 = 0x01;
    /// The parameter error dev's own header names: an address off the end of
    /// the card, or an erase with no range behind it.
    pub const parameter: u8 = 0x40;
};

/// R1, a data token, a block and its checksum: the longest reply staged.
pub const capacity: usize = 2 + image.geometry.block_bytes + 2;

pub const Reply = struct {
    buf: [capacity]u8 = .{0} ** capacity,
    len: usize = 0,
    pos: usize = 0,

    pub fn pending(self: *const Reply) bool {
        return self.pos < self.len;
    }

    /// The next byte of the reply. Only call it with one pending.
    pub fn next(self: *Reply) u8 {
        const byte = self.buf[self.pos];
        self.pos += 1;
        return byte;
    }

    /// One R1 status byte, which is most of what a card says.
    pub fn one(self: *Reply, status: u8) void {
        self.buf[0] = status;
        self.len = 1;
        self.pos = 0;
    }

    pub fn two(self: *Reply, first: u8, second: u8) void {
        self.buf[0] = first;
        self.buf[1] = second;
        self.len = 2;
        self.pos = 0;
    }

    /// A data response, then the busy byte and the line coming back up.
    pub fn dataResponse(self: *Reply, response: u8) void {
        self.buf[0] = response;
        self.buf[1] = token.busy;
        self.buf[2] = token.idle;
        self.len = 3;
        self.pos = 0;
    }

    /// R1 and the four-byte tail of an R3 or R7.
    pub fn tail(self: *Reply, status: u8, rest: [4]u8) void {
        self.buf[0] = status;
        @memcpy(self.buf[1..5], &rest);
        self.len = 5;
        self.pos = 0;
    }

    /// R1, the data token, the payload, and the CRC16 behind it.
    pub fn block(self: *Reply, payload: []const u8) void {
        self.buf[0] = r1.ready;
        self.buf[1] = token.data;
        @memcpy(self.buf[2 .. 2 + payload.len], payload);
        const sum = sd_crc.crc16(payload);
        self.buf[2 + payload.len] = @intCast(sum >> 8);
        self.buf[3 + payload.len] = @intCast(sum & 0xFF);
        self.len = payload.len + 4;
        self.pos = 0;
    }

    /// Start the drain at the data token instead of R1: a block mid-stream
    /// carries no status byte.
    pub fn skipStatus(self: *Reply) void {
        self.pos = 1;
    }
};
