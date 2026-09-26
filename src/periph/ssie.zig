//! SSIE: the I2S serial sound interface, and the transmit FIFO that decides
//! when a sample written to it is actually on the wire.
//!
//! SSIE0 sits at 0x4025_D000 and SSIE1 0x100 above it (ra8_ssie_regs.h). A
//! driver brings a channel up by checking SSISR.IIRQ, programming SSICR and
//! SSIFCR, setting TEN, and then storing one sample per SSIFTDR write. There
//! is no audio clock and no I2S frame here: what a headless run can observe
//! is that handshake and the sample stream it produces, which is what the
//! `ssie_audio_loop` example is worth checking.
//!
//! Ported from board_periph_ssie.c on dev, with three things that model does
//! not do.
//!
//! THE TRANSMIT FIFO IS REAL, NOT A HOLE IN THE FLOOR. dev pins SSIFSR.TDE
//! set and drops every SSIFTDR store straight into a tally, so the register
//! never fills, never stalls, and never loses anything. Here the stage count
//! is the model's own (see `tx_depth`), but it is finite: TDE reads clear
//! while the FIFO holds a sample, and a store past the last stage is dropped
//! and counted rather than silently becoming a transmitted sample.
//!
//! A SAMPLE IS TRANSMITTED WHEN THE TRANSMITTER IS ON. dev counts every
//! SSIFTDR store whatever SSICR says, so an image whose TEN never took
//! reports a stream it never shifted out. Here a store with TEN clear stages
//! the sample, exactly as silicon fills the FIFO ahead of the enable, and
//! setting TEN drains what is staged; a run that never sets it reports the
//! samples as staged, which is the failure the tally was meant to catch.
//!
//! SSISR IS STATUS, NOT A SHADOW. dev stores a write to SSISR into the same
//! flat register array that its read path then ignores, so firmware can
//! neither set a flag nor clear one and cannot tell which happened. Here the
//! register is computed on read and a write to it changes nothing.
//!
//! NOT MODELLED, AND NOT GUESSED: SSIFCR's FIFO resets and SSIFSR's data
//! counts and receive flags. No header for this part is in this tree to say
//! which bits those are, so only the three fields dev's own masks name are
//! interpreted, SSICR.REN/TEN, SSISR.IIRQ and SSIFSR.TDE. The rest of the
//! window is shadowed so a read-modify-write survives, and never read. There
//! is no receive source, so SSIFRDR reads zero, as it does on dev.
const std = @import("std");
const periph = @import("registry.zig");

/// SSIE geometry. The Non-secure alias is folded onto this base by the bus.
pub const win_base: u32 = 0x4025_D000;
pub const channel_stride: u32 = 0x100;
pub const channel_count: usize = 2;
pub const win_span: u32 = channel_stride * @as(u32, channel_count);

/// The registers this model interprets. Everything else in the window is
/// shadow.
pub const off_ssicr: u32 = 0x00;
pub const off_ssisr: u32 = 0x04;
pub const off_ssifcr: u32 = 0x10;
pub const off_ssifsr: u32 = 0x14;
pub const off_ssiftdr: u32 = 0x18;
pub const off_ssifrdr: u32 = 0x1C;

/// The fields dev's own masks name.
pub const field = struct {
    /// SSICR.REN, the receiver enable.
    pub const ren: u32 = 0x0000_0001;
    /// SSICR.TEN, the transmitter enable.
    pub const ten: u32 = 0x0000_0002;
    /// SSISR.IIRQ, the idle flag the driver waits on before enabling.
    pub const iirq: u32 = 0x0200_0000;
    /// SSIFSR.TDE, transmit FIFO empty.
    pub const tde: u32 = 0x0001_0000;
};

/// Stages in the transmit FIFO. The count is the model's, not a number read
/// from a header in this tree; what matters against dev is that it is finite,
/// so TDE means something and an overrun is visible.
pub const tx_depth: usize = 8;

/// Words of a channel's window this model shadows rather than interprets.
const shadow_words: usize = channel_stride / 4;

/// One SSIE channel: its control state, the samples queued behind it, and
/// what the run should be told about the stream it was given.
pub const Channel = struct {
    /// SSICR. Only REN and TEN are read; the rest rides along untouched.
    ssicr: u32 = 0,
    shadow: [shadow_words]u32 = .{0} ** shadow_words,
    /// Samples written while the transmitter was off, oldest first.
    fifo: [tx_depth]u32 = .{0} ** tx_depth,
    staged: usize = 0,
    /// Samples shifted out with TEN set.
    transmitted: u32 = 0,
    /// The last sample shifted out.
    last: u32 = 0,
    /// Samples written to a full FIFO with the transmitter off.
    dropped: u32 = 0,

    pub fn transmitting(self: *const Channel) bool {
        return self.ssicr & field.ten != 0;
    }

    /// IIRQ asserts while neither direction is enabled. The driver reads it
    /// before setting REN/TEN and refuses to start without it.
    pub fn idle(self: *const Channel) bool {
        return self.ssicr & (field.ren | field.ten) == 0;
    }

    pub fn quiet(self: *const Channel) bool {
        return self.ssicr == 0 and self.transmitted == 0 and
            self.staged == 0 and self.dropped == 0;
    }

    /// Take a sample. With the transmitter on it goes out; with it off the
    /// FIFO holds it, because staging ahead of the enable is how a driver
    /// starts a stream without a gap, and a full FIFO is an overrun rather
    /// than one more sample on the wire.
    fn push(self: *Channel, sample: u32) void {
        if (self.transmitting()) return self.shift(sample);
        if (self.staged >= tx_depth) {
            self.dropped +%= 1;
            return;
        }
        self.fifo[self.staged] = sample;
        self.staged += 1;
    }

    fn shift(self: *Channel, sample: u32) void {
        self.last = sample;
        self.transmitted +%= 1;
    }

    /// Enabling the transmitter starts shifting whatever the FIFO already
    /// holds, oldest first.
    fn drain(self: *Channel) void {
        for (self.fifo[0..self.staged]) |sample| self.shift(sample);
        self.staged = 0;
    }

    fn status(self: *const Channel) u32 {
        return if (self.idle()) field.iirq else 0;
    }

    fn fifoStatus(self: *const Channel) u32 {
        return if (self.staged == 0) field.tde else 0;
    }
};

pub const Ssie = struct {
    channels: [channel_count]Channel = .{Channel{}} ** channel_count,

    pub fn init() Ssie {
        return .{};
    }

    pub fn quiet(self: *const Ssie) bool {
        for (&self.channels) |*unit| {
            if (!unit.quiet()) return false;
        }
        return true;
    }

    pub fn read(self: *Ssie, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        const index = offset / channel_stride;
        if (index >= channel_count) return 0;
        const unit = &self.channels[index];
        const inner = offset % channel_stride;
        const byte = inner % 4;
        return switch (inner & ~@as(u32, 3)) {
            off_ssicr => part(unit.ssicr, byte, width),
            off_ssisr => part(unit.status(), byte, width),
            off_ssifsr => part(unit.fifoStatus(), byte, width),
            // Write-only port, and no receive source behind the other one.
            off_ssiftdr, off_ssifrdr => 0,
            else => part(unit.shadow[inner / 4], byte, width),
        };
    }

    pub fn write(self: *Ssie, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        const index = offset / channel_stride;
        if (index >= channel_count) return;
        const unit = &self.channels[index];
        const inner = offset % channel_stride;
        const byte = inner % 4;
        switch (inner & ~@as(u32, 3)) {
            off_ssicr => control(unit, merge(unit.ssicr, byte, width, value)),
            off_ssiftdr => unit.push(value & widthMask(width)),
            // Status, and a status register does not take a store.
            off_ssisr, off_ssifsr => {},
            else => {
                const word = inner / 4;
                unit.shadow[word] = merge(unit.shadow[word], byte, width, value);
            },
        }
    }

    pub fn block(self: *Ssie) periph.Block {
        return .{
            .name = "SSIE",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

/// Take a new SSICR. The transmitter coming on is the edge that matters:
/// everything staged behind it starts moving.
fn control(unit: *Channel, value: u32) void {
    const was = unit.transmitting();
    unit.ssicr = value;
    if (!was and unit.transmitting()) unit.drain();
}

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
    const self: *Ssie = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Ssie = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}

/// The base address of one channel, so a test or a later slice does not do
/// the arithmetic itself.
pub fn channelAddress(index: usize) u32 {
    return win_base + @as(u32, @intCast(index)) * channel_stride;
}
