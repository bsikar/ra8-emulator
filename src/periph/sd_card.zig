//! The SD card on the SPI line: the SPI-mode command set a card answers, and
//! the difference between a card that was brought up and one that was not.
//!
//! The driver clocks one byte at a time through SPDR: a six-byte command
//! frame goes out, the card answers R1, and a block arrives behind a data
//! token with a CRC16 after it. There is no chip select in this tree, so a
//! command self-frames off its `01xxxxxx` lead bits, which is what dev does
//! too and what the firmware's own `ra8_sdmmc_spi` driver makes work.
//!
//! Ported from board_periph_sd.c on dev, with five things that model does
//! not do.
//!
//! A DATA COMMAND NEEDS A CARD THAT CAME UP. dev answers CMD17 with a real
//! block, and CMD24 with a ready R1, from reset: the initialisation sequence
//! its own header documents (CMD0, CMD8, CMD55 + ACMD41) changes nothing it
//! checks. An image that skips or fumbles bring-up reads plausible blocks
//! there and nothing on silicon. Here a transfer command before ACMD41 has
//! completed is refused with an idle R1 and no data token, and counted.
//!
//! A BLOCK PAST THE END OF THE CARD IS NOT A BLOCK. dev zero-fills anything
//! past the image and hands it over behind a success token, so a run reading
//! off the end of a short card gets clean zeros and believes them. Here the
//! read is answered with the parameter-error R1 and the read data-error
//! token, the write is refused, and both are counted.
//!
//! THE BLOCK CRC IS CHECKED. dev swallows the two CRC bytes behind a write
//! payload without looking at them and always answers "accepted", so a
//! corrupted block lands in the image and the driver is told it is safe.
//! Here the checksum is verified and a mismatch is answered with the
//! CRC-error data response, with nothing written.
//!
//! AN ERASE NEEDS A RANGE. CMD32 and CMD33 latch the bounds and CMD38
//! performs it; dev's bounds power up at zero and its `end >= start` test
//! passes, so a bare CMD38 with no range ever latched erases block zero, the
//! one block a filesystem cannot afford to lose. Here CMD38 without both
//! bounds is refused and counted.
//!
//! ONE CARD, ONE LINE. dev's card is a single global that SPI0, SPI1 and SCI
//! in SPI mode all clock into, so two channels talking at once interleave
//! into one command framer and neither notices. Here the card is attached to
//! one channel, and that is the model's own rule rather than a register:
//! nothing in this tree says which chip select the card sits on.
//!
//! NOT MODELLED, AND NOT GUESSED: the command CRC7 (the driver sends the two
//! frames that need one with a valid checksum and no test sends a bad one),
//! CMD6 switch, the SD status commands, and card detect or write protect,
//! which are pins rather than protocol. The capacity is the image's own,
//! declared there.
const std = @import("std");
const image = @import("sd_image.zig");
const sd_reply = @import("sd_reply.zig");
const sd_write = @import("sd_write.zig");
const spi = @import("spi.zig");

/// Which SPI_B channel the card is wired to. The model's own rule; see the
/// header.
pub const line_channel: usize = 0;

/// A command frame, as it arrives on the line.
pub const frame = struct {
    pub const length: usize = 6;
    /// The lead bits that open a command: 01xxxxxx.
    pub const start_bits: u8 = 0x40;
    pub const start_mask: u8 = 0xC0;
    /// The command index in the lead byte.
    pub const index_mask: u8 = 0x3F;
};

/// The wire bytes and the staged reply both live next door, so a caller
/// reaches them through one name rather than two.
pub const token = sd_reply.token;
pub const r1 = sd_reply.r1;

/// The commands answered here. Non-exhaustive: anything else gets the plain
/// R1 a real card gives a command it does not implement in this mode.
pub const Command = enum(u8) {
    go_idle = 0,
    send_if_cond = 8,
    send_csd = 9,
    stop = 12,
    set_blocklen = 16,
    read_single = 17,
    read_multi = 18,
    write_single = 24,
    write_multi = 25,
    erase_start = 32,
    erase_end = 33,
    erase = 38,
    app_op_cond = 41,
    app_cmd = 55,
    read_ocr = 58,
    _,
};

/// The CSD v2.0 register, as far as the capacity field this model fills.
const csd = struct {
    pub const length: usize = 16;
    /// CSD_STRUCTURE = 01b, a v2.0 (high capacity) card.
    pub const version: u8 = 0x40;
    /// C_SIZE spans bytes 7..9, six bits wide in the first of them.
    pub const csize_high: usize = 7;
    pub const csize_mid: usize = 8;
    pub const csize_low: usize = 9;
    pub const high_mask: u32 = 0x3F;
};

pub const Card = struct {
    img: image.Image,
    /// Mid command frame.
    collecting: bool = false,
    cmd: [frame.length]u8 = .{0} ** frame.length,
    cmd_len: usize = 0,
    /// The last command was CMD55, so the next one is an ACMD.
    app_cmd: bool = false,
    /// ACMD41 has completed: the card is out of idle.
    ready: bool = false,
    /// The reply the host is part way through clocking out.
    reply: sd_reply.Reply = .{},
    /// An open CMD18 stream, and the block it hands over next.
    stream: bool = false,
    stream_block: u32 = 0,
    write: sd_write.Write = .{},
    /// The bounds CMD32 and CMD33 latch. Null until one is latched, which is
    /// the whole of the erase divergence.
    erase_lo: ?u32 = null,
    erase_hi: ?u32 = null,
    /// Blocks handed out, blocks taken, and blocks an erase gave back.
    reads: u32 = 0,
    writes: u32 = 0,
    erased: u32 = 0,
    /// Command frames the card completed.
    commands: u32 = 0,
    /// Transfer commands refused because the card was never brought up.
    uninit: u32 = 0,
    /// Blocks addressed past the end of the card.
    past_end: u32 = 0,
    /// Write payloads whose checksum did not match.
    crc_rejects: u32 = 0,
    /// CMD38 with no range latched.
    erase_seq: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) Card {
        return .{ .img = image.Image.init(allocator) };
    }

    pub fn deinit(self: *Card) void {
        self.img.deinit();
    }

    pub fn quiet(self: *const Card) bool {
        return self.commands == 0 and self.reads == 0 and self.writes == 0;
    }

    /// One byte out, one byte back: the whole of the card's side of the wire.
    pub fn exchange(self: *Card, tx: u8) u8 {
        if (self.reply.pending()) return self.reply.next();
        if (self.write.active()) return self.writeByte(tx);
        if (self.collecting) return self.collect(tx);
        if (tx & frame.start_mask == frame.start_bits) {
            self.collecting = true;
            self.cmd[0] = tx;
            self.cmd_len = 1;
            return token.idle;
        }
        // An open stream: the host clocking idle is asking for the next
        // block. The lead-bit check stays ahead of this so a CMD12 frame
        // interrupts the stream instead of being swallowed as clocking.
        if (self.stream) return self.streamNext();
        return token.idle;
    }

    /// The seam the SPI channel drives the card through.
    pub fn device(self: *Card) spi.Device {
        return .{ .context = self, .exchangeFn = exchangeThunk };
    }

    fn collect(self: *Card, tx: u8) u8 {
        self.cmd[self.cmd_len] = tx;
        self.cmd_len += 1;
        if (self.cmd_len >= frame.length) {
            self.collecting = false;
            self.process();
        }
        return token.idle;
    }

    fn process(self: *Card) void {
        const index: u8 = self.cmd[0] & frame.index_mask;
        const arg = std.mem.readInt(u32, self.cmd[1..5], .big);
        const was_app = self.app_cmd;
        const status: u8 = if (self.ready) r1.ready else r1.idle;
        self.app_cmd = false;
        self.commands +%= 1;
        const command: Command = @enumFromInt(index);
        if (command == .app_op_cond and was_app) {
            self.ready = true;
            self.reply.one(r1.ready);
            return;
        }
        if (self.dispatchIdent(command, status)) return;
        self.dispatchData(command, arg, status);
    }

    /// Bring-up and configuration: the commands that say who the card is.
    fn dispatchIdent(self: *Card, command: Command, status: u8) bool {
        switch (command) {
            .go_idle => self.reply.one(r1.idle),
            // R7: R1 then the voltage range and the 0xAA check pattern back.
            .send_if_cond => self.reply.tail(r1.idle, .{ 0, 0, 1, 0xAA }),
            .app_cmd => {
                self.app_cmd = true;
                self.reply.one(r1.idle);
            },
            // R3: R1 then OCR, power-up done with CCS set for a high-capacity
            // card and the 3.3V window.
            .read_ocr => self.reply.tail(status, .{ 0xC0, 0x00, 0x80, 0 }),
            .set_blocklen => self.reply.one(r1.ready),
            else => return false,
        }
        return true;
    }

    /// Transfers and erases: the commands that move or lose data.
    fn dispatchData(self: *Card, command: Command, arg: u32, status: u8) void {
        switch (command) {
            .send_csd => self.sendCsd(),
            .read_single, .read_multi => self.beginRead(command == .read_multi, arg),
            .stop => self.stopRead(status),
            .write_single, .write_multi => self.beginWrite(command == .write_multi, arg, status),
            .erase_start => {
                self.erase_lo = arg;
                self.reply.one(status);
            },
            .erase_end => {
                self.erase_hi = arg;
                self.reply.one(status);
            },
            .erase => self.eraseRange(status),
            else => self.reply.one(status),
        }
    }

    fn beginRead(self: *Card, multi: bool, block: u32) void {
        self.stream = false;
        if (!self.ready) {
            self.uninit +%= 1;
            self.reply.one(r1.idle);
            return;
        }
        var payload: image.Block = undefined;
        if (!self.img.read(block, &payload)) {
            self.past_end +%= 1;
            self.reply.two(r1.parameter, token.read_error);
            return;
        }
        self.reply.block(&payload);
        self.reads +%= 1;
        self.stream = multi;
        self.stream_block = block +% 1;
    }

    /// The next block of an open CMD18 stream. Mid-stream blocks carry no R1:
    /// the card just sends the next data token.
    fn streamNext(self: *Card) u8 {
        var payload: image.Block = undefined;
        if (!self.img.read(self.stream_block, &payload)) {
            self.past_end +%= 1;
            self.stream = false;
            self.reply.one(token.read_error);
            return self.reply.next();
        }
        self.reply.block(&payload);
        self.reads +%= 1;
        self.stream_block +%= 1;
        // A block mid-stream carries no status byte.
        self.reply.skipStatus();
        return self.reply.next();
    }

    /// CMD12 closes a stream: a stuff byte the driver discards, R1, then one
    /// busy byte, which is how long a card holds the line after a stop.
    fn stopRead(self: *Card, status: u8) void {
        self.stream = false;
        self.reply.tail(token.idle, .{ status, token.busy, token.idle, token.idle });
        self.reply.len = 4;
    }

    fn beginWrite(self: *Card, multi: bool, block: u32, status: u8) void {
        if (!self.ready) {
            self.uninit +%= 1;
            self.reply.one(r1.idle);
            return;
        }
        self.reply.one(status);
        self.write.begin(block, multi);
    }

    fn writeByte(self: *Card, tx: u8) u8 {
        switch (self.write.feed(tx)) {
            .none => {},
            .stopped => {
                // Program time, then the line comes back up.
                self.reply.two(token.busy, token.idle);
            },
            .commit => |done| self.commit(done),
        }
        return token.idle;
    }

    fn commit(self: *Card, done: sd_write.Commit) void {
        if (!done.crc_ok) {
            self.crc_rejects +%= 1;
            self.reply.dataResponse(token.crc_error);
            return;
        }
        if (!self.img.write(done.block, &self.write.buf)) {
            self.past_end +%= 1;
            self.reply.dataResponse(token.write_error);
            return;
        }
        self.writes +%= 1;
        self.reply.dataResponse(token.accepted);
    }

    fn eraseRange(self: *Card, status: u8) void {
        const lo = self.erase_lo orelse {
            self.erase_seq +%= 1;
            self.reply.one(r1.parameter);
            return;
        };
        const hi = self.erase_hi orelse {
            self.erase_seq +%= 1;
            self.reply.one(r1.parameter);
            return;
        };
        self.erase_lo = null;
        self.erase_hi = null;
        if (hi < lo) {
            self.reply.one(status);
            return;
        }
        if (!self.img.inRange(lo)) {
            self.past_end +%= 1;
            self.reply.one(r1.parameter);
            return;
        }
        const last = @min(hi, self.img.capacity_blocks - 1);
        self.erased +%= self.img.zero(lo, last);
        self.reply.one(status);
    }

    /// CMD9: a CSD v2.0 register whose capacity field is the image's own, so
    /// a driver sizing the card sees the card it actually gets.
    fn sendCsd(self: *Card) void {
        var block: [csd.length]u8 = .{0} ** csd.length;
        block[0] = csd.version;
        const size = self.img.csize();
        block[csd.csize_high] = @intCast((size >> 16) & csd.high_mask);
        block[csd.csize_mid] = @intCast((size >> 8) & 0xFF);
        block[csd.csize_low] = @intCast(size & 0xFF);
        self.reply.block(&block);
    }
};

fn exchangeThunk(context: *anyopaque, tx: u8) u8 {
    const self: *Card = @ptrCast(@alignCast(context));
    return self.exchange(tx);
}
