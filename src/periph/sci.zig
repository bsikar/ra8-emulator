//! SCI_B: the serial channels, so a console print ends instead of spinning.
//!
//! The RA8D2 puts ten SCI_B channels at 0x4035_8000, 0x100 apart (HUM Ch 29,
//! ra8_sci_regs.h, the 32-bit-register variant). The EK-RA8D2 console is SCI8
//! on PD02/PD03, and it is the block every non-display example reaches first:
//! `ra8_sci_putc_polling` writes a byte and then waits on CSR.TDRE, and
//! `ra8_sci_getc_polling` waits on CSR.RDRF. Until now the window fell through
//! to the sparse register file, where a status poll gets alternating stand-in
//! values rather than a transmitter that drains, so console output was a race
//! against the instruction budget instead of a result. Ported from
//! board_periph_sci.c on dev.
//!
//!   RDR   (+0x00) receive data, RDAT[7:0]
//!   TDR   (+0x04) transmit data, TDAT[7:0]
//!   CCR0  (+0x08) RE, TE and the three interrupt enables
//!   CSR   (+0x48) TDRE, TEND, RDRF, RXDMON
//!   FRSR  (+0x50) receive-FIFO status
//!   FTSR  (+0x54) transmit-FIFO status
//!   CFCLR (+0x68) common flag clear, write-1-to-clear
//!   FFCLR (+0x70) FIFO flag clear, write-1-to-clear
//!
//! The transmitter is always drained here: there is no baud-rate clock in an
//! instruction-stepped emulator, so a byte written to TDR is captured and gone,
//! and TDRE/TEND read as set. The receiver is a host-fed ring per channel, so
//! RDRF is a fact about queued bytes rather than a value a driver wrote.
const std = @import("std");
const periph = @import("registry.zig");

/// SCI_B geometry. The Non-secure alias is folded onto this base by the bus
/// before anything here sees it.
pub const win_base: u32 = 0x4035_8000;
pub const stride: u32 = 0x100;
pub const channels: usize = 10;
pub const win_span: u32 = stride * channels;

/// The EK-RA8D2 console channel: SCI8, the one carrying UART text.
pub const console_channel: usize = 8;

pub const off_rdr: u32 = 0x00;
pub const off_tdr: u32 = 0x04;
pub const off_ccr0: u32 = 0x08;
pub const off_csr: u32 = 0x48;
pub const off_frsr: u32 = 0x50;
pub const off_ftsr: u32 = 0x54;
pub const off_cfclr: u32 = 0x68;
pub const off_ffclr: u32 = 0x70;

/// CCR0 enables (ra8_sci_ccr0_bit_t).
pub const ccr0 = struct {
    pub const re: u32 = 0x0000_0001;
    pub const te: u32 = 0x0000_0010;
    pub const rie: u32 = 0x0001_0000;
    pub const tie: u32 = 0x0010_0000;
    pub const teie: u32 = 0x0020_0000;
};

/// CSR status bits (ra8_sci_csr_bit_t).
pub const csr = struct {
    pub const rxdmon: u32 = 0x0000_8000;
    pub const tdre: u32 = 0x2000_0000;
    pub const tend: u32 = 0x4000_0000;
    pub const rdrf: u32 = 0x8000_0000;
};

/// FIFO status bits a read of FRSR / FTSR reports.
pub const fifo = struct {
    pub const frsr_dr: u32 = 0x0000_0001;
    pub const frsr_rdf: u32 = 0x0000_0040;
    pub const ftsr_tdfe: u32 = 0x0000_0040;
};

pub const data_mask: u32 = 0xFF;

/// Model sizing. The RX ring is per channel; the line buffer only ever holds
/// console text.
pub const limits = struct {
    pub const rx_queue: usize = 512;
    pub const line: usize = 512;
};

/// A host-to-firmware byte ring. Fixed capacity on purpose: the model has no
/// allocator below the bus, and a real UART drops what it cannot hold too.
pub const Ring = struct {
    bytes: [limits.rx_queue]u8 = undefined,
    head: usize = 0,
    tail: usize = 0,
    dropped: u32 = 0,

    pub fn empty(self: *const Ring) bool {
        return self.head == self.tail;
    }

    /// Queue what fits and count what does not.
    pub fn push(self: *Ring, data: []const u8) void {
        for (data, 0..) |byte, i| {
            const next = (self.tail + 1) % limits.rx_queue;
            if (next == self.head) {
                self.dropped += @intCast(data.len - i);
                return;
            }
            self.bytes[self.tail] = byte;
            self.tail = next;
        }
    }

    pub fn pop(self: *Ring) ?u8 {
        if (self.empty()) return null;
        const byte = self.bytes[self.head];
        self.head = (self.head + 1) % limits.rx_queue;
        return byte;
    }
};

/// One channel: the control shadow, the byte counters and the RX ring.
pub const Channel = struct {
    control: u32 = 0,
    transmitted: u32 = 0,
    received: u32 = 0,
    /// TDR writes made while CCR0.TE was clear, which silicon does not send.
    unsent: u32 = 0,
    rx: Ring = .{},

    pub fn enabled(self: *const Channel, bit: u32) bool {
        return self.control & bit != 0;
    }

    pub fn quiet(self: *const Channel) bool {
        return self.transmitted == 0 and self.received == 0 and self.unsent == 0;
    }

    /// CSR: the transmitter is always drained, RXDMON idles high the way an
    /// idle line does, and RDRF is true only while the receiver is enabled and
    /// a byte is queued.
    pub fn status(self: *const Channel) u32 {
        var value: u32 = csr.tdre | csr.tend | csr.rxdmon;
        if (self.readable()) value |= csr.rdrf;
        return value;
    }

    pub fn readable(self: *const Channel) bool {
        return self.enabled(ccr0.re) and !self.rx.empty();
    }
};

/// The captured console line. The last finished line is kept as a slice, not a
/// terminated buffer: nothing here crosses a C boundary.
pub const Line = struct {
    last: [limits.line]u8 = undefined,
    last_len: usize = 0,
    pending: [limits.line]u8 = undefined,
    pending_len: usize = 0,
    lines: u32 = 0,

    pub fn slice(self: *const Line) []const u8 {
        return self.last[0..self.last_len];
    }

    /// Accumulate one transmitted byte. A newline latches the pending line,
    /// carriage return is dropped, and an over-long line stops growing rather
    /// than wrapping onto itself.
    pub fn feed(self: *Line, byte: u8) void {
        if (byte == '\n') {
            @memcpy(self.last[0..self.pending_len], self.pending[0..self.pending_len]);
            self.last_len = self.pending_len;
            self.pending_len = 0;
            self.lines += 1;
            return;
        }
        if (byte == '\r' or self.pending_len == limits.line) return;
        self.pending[self.pending_len] = byte;
        self.pending_len += 1;
    }
};

/// The block: ten channels and the console line capture.
pub const Sci = struct {
    channels: [channels]Channel = [_]Channel{.{}} ** channels,
    line: Line = .{},

    pub fn init() Sci {
        return .{};
    }

    pub fn quiet(self: *const Sci) bool {
        for (&self.channels) |*channel| {
            if (!channel.quiet()) return false;
        }
        return true;
    }

    pub fn console(self: *Sci) *Channel {
        return &self.channels[console_channel];
    }

    /// Queue host bytes for the firmware to read out of RDR.
    pub fn feed(self: *Sci, channel: usize, data: []const u8) void {
        if (channel >= channels) return;
        self.channels[channel].rx.push(data);
    }

    pub fn read(self: *Sci, address: u32, width: u3) u32 {
        _ = width;
        const offset = address -% win_base;
        const index = offset / stride;
        if (index >= channels) return 0;
        return self.readRegister(@intCast(index), offset % stride);
    }

    fn readRegister(self: *Sci, index: usize, offset: u32) u32 {
        const channel = &self.channels[index];
        return switch (offset) {
            off_rdr => self.readData(index),
            off_ccr0 => channel.control,
            off_csr => channel.status(),
            off_frsr => if (channel.readable()) fifo.frsr_dr | fifo.frsr_rdf else 0,
            // The transmit FIFO is always empty in this model, for the same
            // reason TDRE is always set.
            off_ftsr => fifo.ftsr_tdfe,
            // The clear strobes are write-only, and nothing else in the
            // channel answers: zero beats the sparse file's alternating
            // stand-in here, because these are registers with no value.
            else => 0,
        };
    }

    /// RDR takes the oldest queued byte. A read with the receiver disabled, or
    /// with nothing queued, reads zero and is not counted as received.
    fn readData(self: *Sci, index: usize) u32 {
        const channel = &self.channels[index];
        if (!channel.readable()) return 0;
        const byte = channel.rx.pop() orelse return 0;
        channel.received += 1;
        return byte;
    }

    pub fn write(self: *Sci, address: u32, width: u3, value: u32) void {
        _ = width;
        const offset = address -% win_base;
        const index = offset / stride;
        if (index >= channels) return;
        self.writeRegister(@intCast(index), offset % stride, value);
    }

    fn writeRegister(self: *Sci, index: usize, offset: u32, value: u32) void {
        switch (offset) {
            off_tdr => self.writeData(index, @truncate(value & data_mask)),
            off_ccr0 => self.channels[index].control = value,
            // CFCLR and FFCLR are write-1-to-clear over flags this model
            // derives rather than latches: TDRE and TEND never go down, and
            // RDRF follows the queue, so clearing them changes nothing.
            else => {},
        }
    }

    /// A byte handed to the transmitter. With CCR0.TE clear the transmitter is
    /// not running, so the frame is never launched: the write is counted and
    /// dropped, which is what silicon does and what the emulator used to hide.
    fn writeData(self: *Sci, index: usize, byte: u8) void {
        const channel = &self.channels[index];
        if (!channel.enabled(ccr0.te)) {
            channel.unsent += 1;
            return;
        }
        channel.transmitted += 1;
        if (index == console_channel) self.line.feed(byte);
    }

    pub fn block(self: *Sci) periph.Block {
        return .{
            .name = "SCI_B UART",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Sci = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Sci = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}

/// The address of one register on one channel, so a test or a later slice does
/// not have to do the arithmetic itself.
pub fn regAddress(channel: usize, offset: u32) u32 {
    return win_base + @as(u32, @intCast(channel)) * stride + offset;
}
