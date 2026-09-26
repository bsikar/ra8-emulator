//! PDM-IF: the digital MEMS microphone port, and the FIFO that decides
//! whether a sample a capture loop reads was ever produced.
//!
//! The single PDM-IF block sits at 0x4025_6000 with a common bank and three
//! channel banks above it (ra8_pdm_regs.h). A driver starts a channel with a
//! bit in PDCSTRTR, arms the read port with PDDRCR.DATRE, polls PDDSR.NUM for
//! the number of samples waiting, drains that many 20-bit words out of PDDRR,
//! and stops the channel by writing PDCSTPTR and spinning on PDCSR until the
//! run bit clears. There is no microphone behind this model and no PDM clock,
//! so the sample values are a synthetic tone: the port is a run-headless
//! enabler, not a claim about an analog input.
//!
//! Ported from board_periph_pdm.c on dev, with three things that model does
//! not do.
//!
//! THE FIFO IS FINITE AND HAS TO FILL. dev pins PDDSR.NUM at the full depth
//! for as long as a channel is live, so the FIFO never empties and PDDRR
//! manufactures a fresh sample on every read. A capture loop can then ask for
//! any number of samples and always get them, which is the one thing a
//! microphone run is worth checking: an image that drains faster than the mic
//! produces should starve. Here samples are produced at the board's chunk
//! boundary, NUM is the level the FIFO actually holds, a read past it is
//! refused and counted, and production into a full FIFO is an overrun and
//! counted too.
//!
//! PDCSR IS STATUS AND THE TRIGGERS ARE TRIGGERS. dev drops every store in
//! the window into a flat shadow array, so PDCSR takes a write its own read
//! path then ignores, and PDCSTRTR reads back whatever bit pattern was last
//! written to it as if that were run state. Here PDCSR is computed on read
//! and refuses a store, and the two trigger registers read zero: the run
//! state is in PDCSR, which is where the stop path already looks for it.
//!
//! A NARROW WRITE KEEPS THE BYTES IT DOES NOT NAME. dev stores the whole
//! 32-bit value into the addressed word, so a byte store to PDDRCR.DATRE
//! wipes the bytes above it, and a byte store one past a register lands on
//! the register itself. Here narrow accesses merge.
//!
//! KEPT FROM DEV DELIBERATELY: a channel produces nothing until it has BOTH
//! been started and had its read path enabled, and the tone is dev's own
//! triangle plus LCG dither with the same constants, so a given channel's
//! nth sample is the same value it was under the C model.
//!
//! NOT MODELLED, AND NOT GUESSED: the sampling-rate, filter and gain
//! registers, the interrupt and error-status fields, and the receive-format
//! control. No header for this part is in this tree to say which bits those
//! are, so only the three fields dev's own masks name are interpreted,
//! PDDRCR.DATRE, PDDSR.NUM and PDDRR's 20-bit data field. The rest of the
//! window is shadowed so a read-modify-write survives, and never read.
const std = @import("std");
const periph = @import("registry.zig");

/// PDM-IF geometry (ra8_pdm_regs.h, and dev's own k_pdm_* window).
pub const win_base: u32 = 0x4025_6000;
pub const win_span: u32 = 0x400;
pub const channel_count: usize = 3;
pub const channel_base: u32 = 0x100;
pub const channel_stride: u32 = 0x100;

/// The common bank.
pub const off_cstrtr: u32 = 0x00;
pub const off_cstptr: u32 = 0x04;
pub const off_csr: u32 = 0x10;

/// A channel bank.
pub const off_ddrcr: u32 = 0xE0;
pub const off_ddrr: u32 = 0xE8;
pub const off_ddsr: u32 = 0xEC;

/// The fields dev's own masks name.
pub const field = struct {
    /// PDDRCR[0], the data-read enable.
    pub const datre: u32 = 0x0000_0001;
    /// PDDSR[7:0], the FIFO fill count.
    pub const num: u32 = 0x0000_00FF;
    /// PDDRR[19:0], one two's-complement PCM sample.
    pub const sample: u32 = 0x000F_FFFF;
};

/// The synthetic tone, ported value for value from dev so a channel's nth
/// sample does not change with the language.
pub const tone = struct {
    pub const period: u32 = 64;
    pub const half: u32 = 32;
    pub const amplitude: i32 = 20000;
    pub const step: i32 = 1250;
    pub const lcg_multiplier: u32 = 1664525;
    pub const lcg_increment: u32 = 1013904223;
    pub const lcg_shift: u5 = 16;
    pub const dither_mask: u32 = 0x3FF;
    pub const dither_centre: i32 = 512;
};

/// Stages in a channel's receive FIFO, dev's own k_pdm_fifo_depth. dev
/// reports this number forever; here it is a ceiling.
pub const fifo_depth: usize = 32;

/// Samples a live channel produces per chunk boundary: one FIFO window of
/// microphone input per unit of modelled time. The number is the model's
/// own, not one read from a header in this tree. What matters against dev is
/// that it is finite and arrives on the clock, so a loop that drains the
/// window has to wait for the next one instead of being served forever.
pub const samples_per_tick: usize = fifo_depth;

/// Words of a bank this model shadows rather than interprets.
const shadow_words: usize = channel_stride / 4;

/// One PDM channel: the two gates, the FIFO behind them, and what the run
/// should be told about the stream it was given.
pub const Channel = struct {
    running: bool = false,
    read_enable: bool = false,
    shadow: [shadow_words]u32 = .{0} ** shadow_words,
    /// Produced and not yet read, oldest first.
    fifo: [fifo_depth]u32 = .{0} ** fifo_depth,
    filled: usize = 0,
    /// Tone state, advanced when a sample is produced.
    phase: u32 = 0,
    lcg: u32 = 0,
    /// Samples handed to firmware through PDDRR.
    read: u32 = 0,
    last: u32 = 0,
    /// PDDRR reads served nothing because the FIFO was empty.
    starved: u32 = 0,
    /// Samples the microphone produced into a full FIFO.
    overrun: u32 = 0,

    pub fn live(self: *const Channel) bool {
        return self.running and self.read_enable;
    }

    pub fn quiet(self: *const Channel) bool {
        return !self.running and !self.read_enable and self.read == 0 and
            self.starved == 0 and self.overrun == 0 and self.filled == 0;
    }

    /// The next tone sample, dev's triangle plus its LCG dither.
    fn nextSample(self: *Channel) u32 {
        const phase = self.phase % tone.period;
        const ramp: i32 = @intCast(phase % tone.half);
        const value: i32 = if (phase < tone.half)
            -tone.amplitude + tone.step * ramp
        else
            tone.amplitude - tone.step * ramp;
        self.lcg = self.lcg *% tone.lcg_multiplier +% tone.lcg_increment;
        const spread: i32 = @intCast((self.lcg >> tone.lcg_shift) & tone.dither_mask);
        self.phase +%= 1;
        const sample: i32 = value + (spread - tone.dither_centre);
        return @as(u32, @bitCast(sample)) & field.sample;
    }

    /// One window of microphone input. A full FIFO is an overrun:
    /// the sample is lost, which is what silicon does and what a capture
    /// loop too slow to keep up needs to be told.
    pub fn produce(self: *Channel, count: usize) void {
        if (!self.live()) return;
        for (0..count) |_| {
            const sample = self.nextSample();
            if (self.filled >= fifo_depth) {
                self.overrun +%= 1;
                continue;
            }
            self.fifo[self.filled] = sample;
            self.filled += 1;
        }
    }

    /// PDDRR. An empty FIFO hands back nothing rather than inventing a
    /// sample, and the refusal is counted.
    fn take(self: *Channel) u32 {
        if (self.filled == 0) {
            self.starved +%= 1;
            return 0;
        }
        const sample = self.fifo[0];
        for (1..self.filled) |index| self.fifo[index - 1] = self.fifo[index];
        self.filled -= 1;
        self.read +%= 1;
        self.last = sample;
        return sample;
    }

    /// PDDSR.NUM, the level the FIFO is actually holding. A channel that is
    /// not live holds nothing to report.
    fn status(self: *const Channel) u32 {
        if (!self.live()) return 0;
        return @as(u32, @intCast(self.filled)) & field.num;
    }

    /// Stopping drops what the FIFO was holding: those samples were never
    /// read, and a restarted channel is a new capture, not a continuation.
    fn stop(self: *Channel) void {
        self.running = false;
        self.filled = 0;
    }
};

pub const Pdm = struct {
    channels: [channel_count]Channel = .{Channel{}} ** channel_count,

    pub fn init() Pdm {
        return .{};
    }

    pub fn quiet(self: *const Pdm) bool {
        for (&self.channels) |*unit| {
            if (!unit.quiet()) return false;
        }
        return true;
    }

    /// The chunk boundary: every live channel takes another window of
    /// microphone input.
    pub fn tick(self: *Pdm) void {
        for (&self.channels) |*unit| unit.produce(samples_per_tick);
    }

    pub fn read(self: *Pdm, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        if (offset >= win_span) return 0;
        if (offset < channel_base) return self.readCommon(offset, width);
        const index = (offset - channel_base) / channel_stride;
        if (index >= channel_count) return 0;
        const unit = &self.channels[index];
        const inner = (offset - channel_base) % channel_stride;
        const byte = inner % 4;
        return switch (inner & ~@as(u32, 3)) {
            off_ddrcr => part(if (unit.read_enable) field.datre else 0, byte, width),
            off_ddrr => unit.take() & widthMask(width),
            off_ddsr => part(unit.status(), byte, width),
            else => part(unit.shadow[inner / 4], byte, width),
        };
    }

    /// The common bank. The triggers are write-only and the status register
    /// is computed, so nothing here comes out of a shadow.
    fn readCommon(self: *Pdm, offset: u32, width: u3) u32 {
        const byte = offset % 4;
        return switch (offset & ~@as(u32, 3)) {
            off_csr => part(self.runState(), byte, width),
            off_cstrtr, off_cstptr => 0,
            else => 0,
        };
    }

    /// PDCSR: one bit per channel currently started.
    pub fn runState(self: *const Pdm) u32 {
        var state: u32 = 0;
        for (&self.channels, 0..) |*unit, index| {
            if (unit.running) state |= @as(u32, 1) << @intCast(index);
        }
        return state;
    }

    pub fn write(self: *Pdm, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        if (offset >= win_span) return;
        if (offset < channel_base) return self.writeCommon(offset, width, value);
        const index = (offset - channel_base) / channel_stride;
        if (index >= channel_count) return;
        const unit = &self.channels[index];
        const inner = (offset - channel_base) % channel_stride;
        const byte = inner % 4;
        switch (inner & ~@as(u32, 3)) {
            off_ddrcr => {
                const held: u32 = if (unit.read_enable) field.datre else 0;
                unit.read_enable = merge(held, byte, width, value) & field.datre != 0;
            },
            // Read data and status; neither takes a store.
            off_ddrr, off_ddsr => {},
            else => {
                const word = inner / 4;
                unit.shadow[word] = merge(unit.shadow[word], byte, width, value);
            },
        }
    }

    /// A trigger acts on the bits it names and keeps nothing. PDCSR is
    /// status: a store to it is refused rather than shadowed.
    fn writeCommon(self: *Pdm, offset: u32, width: u3, value: u32) void {
        const bits = part(value, 0, width) << @intCast((offset % 4) * 8);
        switch (offset & ~@as(u32, 3)) {
            off_cstrtr => for (&self.channels, 0..) |*unit, index| {
                if (bits & (@as(u32, 1) << @intCast(index)) != 0) unit.running = true;
            },
            off_cstptr => for (&self.channels, 0..) |*unit, index| {
                if (bits & (@as(u32, 1) << @intCast(index)) != 0) unit.stop();
            },
            else => {},
        }
    }

    pub fn block(self: *Pdm) periph.Block {
        return .{
            .name = "PDM",
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
    const self: *Pdm = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Pdm = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}

/// The base address of one channel bank, so a test or a later slice does not
/// do the arithmetic itself.
pub fn channelAddress(index: usize) u32 {
    return win_base + channel_base + @as(u32, @intCast(index)) * channel_stride;
}
