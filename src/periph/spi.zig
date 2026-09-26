//! SPI_B: the Type-B SPI controller, and the difference between a frame that
//! was clocked out and one the firmware only wrote down.
//!
//! SPI0 sits at 0x4035_C000 and SPI1 0x100 above it (ra8_spi_regs.h). The
//! polling driver brings a channel up by programming SPCR2, setting SPCR.SPE,
//! then clocking one 8-bit frame per SPDR store: wait for SPSR.SPTEF, write
//! SPDR, wait for SPSR.SPRF, read SPDR, clear through SPSRC. There is no bit
//! clock and no pin here, so what a headless run can observe is that
//! handshake and the frames it moved, which is what the `spi_loopback`
//! example is worth checking.
//!
//! Ported from board_periph_spi.c on dev, with four things that model does
//! not do.
//!
//! A FRAME NEEDS AN ENABLED CHANNEL. dev echoes and counts every SPDR store
//! whatever SPCR says, so an image whose SPE never took still reports frames
//! it never clocked, and the receive holding register answers as if the wire
//! were live. Here a store to a disabled channel moves nothing: it is
//! refused and counted, so the run says the channel was never started.
//!
//! A RECEIVED FRAME IS TAKEN ONCE. dev leaves the echoed word in the holding
//! register and SPRF set until SPSRC clears it, so a second SPDR read hands
//! back a frame that was never received. Here a read consumes it: SPRF and
//! SPDRF drop, and a read with nothing pending is refused and counted, the
//! same starve the PDM FIFO reports.
//!
//! CENDF MEANS THE FRAME ENDED. dev names the flag in its own status enum
//! and never asserts it, so a driver that waits for communication end rather
//! than receive-full waits forever. Here a completed frame raises it and
//! SPSRC clears it.
//!
//! NARROW WRITES KEEP THE BYTES THEY DO NOT NAME. dev drops the whole value
//! into reg[off / 4], so a byte or halfword store to SPCR2 wipes the loopback
//! bits above it and the tie silently comes undone.
//!
//! THE FRAME IS EIGHT BITS, and that is this model's own rule rather than a
//! field it reads: no header in this tree gives SPCMD's frame-length bits.
//! dev masks the inverting loopback path to a byte and echoes the whole word
//! on the non-inverting one, which cannot both be right; here both paths use
//! the same width, and a store with bits above it keeps only the frame.
//!
//! A DEVICE CAN BE ON THE LINE. A channel with no loopback and nothing
//! attached clocks in an idle zero, as it does on dev with no card and no
//! display; a channel with a device attached hands it the frame and takes
//! back what it drives. Only one device per channel, and the loopback ties
//! are checked first, which is dev's own order: an internal tie replaces the
//! wire, so whatever is on the wire does not get the frame.
//!
//! NOT MODELLED, AND NOT GUESSED: SPCMD frame length and bit order, SPBR bit
//! rate, SPSSR slave select, and the mode-fault, overrun and parity errors.
//! The rest of the window is shadowed so a read-modify-write survives, and
//! never read.
const std = @import("std");
const periph = @import("registry.zig");

/// SPI_B geometry. The Non-secure alias is folded onto this base by the bus.
pub const win_base: u32 = 0x4035_C000;
pub const channel_stride: u32 = 0x100;
pub const channel_count: usize = 2;
pub const win_span: u32 = channel_stride * @as(u32, channel_count);

/// The registers this model interprets. Everything else in the window is
/// shadow.
pub const off_spdr: u32 = 0x00;
pub const off_spcr: u32 = 0x08;
pub const off_spcr2: u32 = 0x0C;
pub const off_spsr: u32 = 0x50;
pub const off_spsrc: u32 = 0x68;

/// The fields dev's own masks name.
pub const field = struct {
    /// SPCR.SPE, the function enable that starts the channel.
    pub const spe: u32 = 0x0000_0001;
    /// SPCR2.SPLP, the inverting internal tie (rx = ~tx).
    pub const splp: u32 = 0x0001_0000;
    /// SPCR2.SPLP2, the non-inverting internal tie (rx = tx).
    pub const splp2: u32 = 0x0002_0000;
    /// SPSR.SPDRF, receive data ready.
    pub const spdrf: u32 = 0x0080_0000;
    /// SPSR.SPTEF, transmit buffer empty.
    pub const sptef: u32 = 0x2000_0000;
    /// SPSR.CENDF, communication end.
    pub const cendf: u32 = 0x4000_0000;
    /// SPSR.SPRF, receive buffer full.
    pub const sprf: u32 = 0x8000_0000;
};

/// The data path this model clocks. Eight bits is the width the polling
/// driver uses and the width dev's own inverting path masks to; no header in
/// this tree names the frame-length field, so this is the model's rule and
/// not a register read.
pub const frame_mask: u32 = 0xFF;

/// Something on the other end of the line: one frame out, one frame back.
/// The SD card is the first of them; a display controller is the other one
/// dev drives this way.
pub const Device = struct {
    context: *anyopaque,
    exchangeFn: *const fn (*anyopaque, u8) u8,

    pub fn exchange(self: Device, byte: u8) u8 {
        return self.exchangeFn(self.context, byte);
    }
};

/// Words of a channel's window this model shadows rather than interprets.
const shadow_words: usize = channel_stride / 4;

/// One SPI_B channel: its control state, the frame waiting in the receive
/// holding register, and what the run should be told about the traffic it
/// was given.
pub const Channel = struct {
    /// SPCR. Only SPE is read; the rest rides along untouched.
    spcr: u32 = 0,
    /// SPCR2. Only the two loopback bits are read.
    spcr2: u32 = 0,
    shadow: [shadow_words]u32 = .{0} ** shadow_words,
    /// The receive holding register, and whether anything is in it.
    rx: u32 = 0,
    rx_full: bool = false,
    /// Flags SPSRC owns: CENDF once a frame ended, and the two receive bits
    /// while the holding register is loaded.
    ended: bool = false,
    /// Frames clocked out with SPE set.
    frames: u32 = 0,
    /// The last frame clocked out.
    last: u32 = 0,
    /// SPDR stores made with SPE clear: nothing left the channel.
    refused: u32 = 0,
    /// SPDR reads made with the holding register empty.
    starved: u32 = 0,
    /// What is on the wire, when anything is.
    device: ?Device = null,

    pub fn enabled(self: *const Channel) bool {
        return self.spcr & field.spe != 0;
    }

    pub fn inverting(self: *const Channel) bool {
        return self.spcr2 & field.splp != 0;
    }

    pub fn loopback(self: *const Channel) bool {
        return self.spcr2 & (field.splp | field.splp2) != 0;
    }

    pub fn quiet(self: *const Channel) bool {
        return self.spcr == 0 and self.spcr2 == 0 and self.frames == 0 and
            self.refused == 0 and self.starved == 0;
    }

    /// Clock one frame. Without an enabled channel there is no clock, so the
    /// store moves nothing: on silicon SPDR would sit in the transmit buffer
    /// until SPE arrives, and the run needs to know it never did.
    fn send(self: *Channel, value: u32) void {
        if (!self.enabled()) {
            self.refused +%= 1;
            return;
        }
        const word = value & frame_mask;
        self.rx = self.receive(word);
        self.rx_full = true;
        self.ended = true;
        self.last = word;
        self.frames +%= 1;
    }

    /// What the receive shifter clocks in behind that frame. The inverting
    /// tie is checked first because SPLP and SPLP2 can both be set and only
    /// one line comes back.
    fn receive(self: *Channel, word: u32) u32 {
        if (self.inverting()) return ~word & frame_mask;
        if (self.loopback()) return word;
        if (self.device) |on_line| return on_line.exchange(@intCast(word & frame_mask));
        // Nothing drives the line.
        return 0;
    }

    /// Take the received frame. A read of an empty holding register is a
    /// frame the firmware never received, so it is refused rather than
    /// served the previous one again.
    fn take(self: *Channel) u32 {
        if (!self.rx_full) {
            self.starved +%= 1;
            return 0;
        }
        self.rx_full = false;
        return self.rx;
    }

    /// SPSR is computed, never stored. SPTEF is set while the channel runs
    /// because the model drains the transmit buffer as it takes the frame.
    fn status(self: *const Channel) u32 {
        var value: u32 = 0;
        if (self.enabled()) value |= field.sptef;
        if (self.rx_full) value |= field.sprf | field.spdrf;
        if (self.ended) value |= field.cendf;
        return value;
    }

    /// SPSRC is write-one-to-clear, and it reaches the flags the model holds
    /// rather than the ones it computes: SPTEF follows SPE, and the receive
    /// bits follow the holding register, which only a read empties.
    fn clear(self: *Channel, value: u32) void {
        if (value & field.cendf != 0) self.ended = false;
        if (value & (field.sprf | field.spdrf) != 0) self.rx_full = false;
    }
};

pub const Spi = struct {
    channels: [channel_count]Channel = .{Channel{}} ** channel_count,

    pub fn init() Spi {
        return .{};
    }

    /// Put a device on one channel's line. Attaching twice replaces what was
    /// there; a real board has one thing per chip select.
    pub fn attachDevice(self: *Spi, index: usize, on_line: Device) void {
        if (index >= channel_count) return;
        self.channels[index].device = on_line;
    }

    pub fn quiet(self: *const Spi) bool {
        for (&self.channels) |*unit| {
            if (!unit.quiet()) return false;
        }
        return true;
    }

    pub fn read(self: *Spi, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        const index = offset / channel_stride;
        if (index >= channel_count) return 0;
        const unit = &self.channels[index];
        const inner = offset % channel_stride;
        const byte = inner % 4;
        return switch (inner & ~@as(u32, 3)) {
            off_spdr => part(unit.take(), byte, width),
            off_spcr => part(unit.spcr, byte, width),
            off_spcr2 => part(unit.spcr2, byte, width),
            off_spsr => part(unit.status(), byte, width),
            // Write-one-to-clear, and there is nothing behind it to read.
            off_spsrc => 0,
            else => part(unit.shadow[inner / 4], byte, width),
        };
    }

    pub fn write(self: *Spi, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        const index = offset / channel_stride;
        if (index >= channel_count) return;
        const unit = &self.channels[index];
        const inner = offset % channel_stride;
        const byte = inner % 4;
        switch (inner & ~@as(u32, 3)) {
            off_spdr => unit.send(value & widthMask(width)),
            off_spcr => unit.spcr = merge(unit.spcr, byte, width, value),
            off_spcr2 => unit.spcr2 = merge(unit.spcr2, byte, width, value),
            // Status, and a status register does not take a store.
            off_spsr => {},
            off_spsrc => unit.clear(merge(0, byte, width, value)),
            else => {
                const word = inner / 4;
                unit.shadow[word] = merge(unit.shadow[word], byte, width, value);
            },
        }
    }

    pub fn block(self: *Spi) periph.Block {
        return .{
            .name = "SPI_B",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

/// The bits an access of this width names.
fn widthMask(width: u3) u32 {
    return switch (width) {
        1 => 0xFF,
        2 => 0xFFFF,
        else => 0xFFFF_FFFF,
    };
}

/// The part of a 32-bit register a narrow access names.
fn part(value: u32, byte_offset: u32, width: u3) u32 {
    if (width >= 4) return value;
    const shift: u5 = @intCast(byte_offset * 8);
    return (value >> shift) & widthMask(width);
}

/// Fold a narrow write into a 32-bit register, leaving the bytes the access
/// does not name where they were.
fn merge(current: u32, byte_offset: u32, width: u3, value: u32) u32 {
    if (width >= 4) return value;
    const shift: u5 = @intCast(byte_offset * 8);
    const bits = widthMask(width);
    const window: u32 = bits << shift;
    return (current & ~window) | ((value & bits) << shift);
}

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Spi = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Spi = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}

/// The base address of one channel, so a test or a later slice does not do
/// the arithmetic itself.
pub fn channelAddress(index: usize) u32 {
    return win_base + @as(u32, @intCast(index)) * channel_stride;
}
