//! ULPT: the low-power timer a sleeping part wakes itself on.
//!
//! Two channels of a 32-bit reloading down-counter at 0x4022_0000, clocked
//! from the LOCO-derived ULPTLCLK so they keep running through Software
//! Standby (HUM Ch 25 p 1187). That is the whole point of the block: the
//! deep-idle images arm a channel, drop into standby on WFI, and rely on the
//! underflow to cancel standby through the ICU. Without a model the underflow
//! never happens, the registered ISR never runs, and the wake count stays
//! zero while the run burns its budget in the wait loop.
//!
//!   ULPTCNT (+0x00, 32b)  counter; a write seeds the count and the reload
//!   ULPTCMA (+0x04, 32b)  compare match A
//!   ULPTCMB (+0x08, 32b)  compare match B
//!   ULPTCR  (+0x0C, 8b)   TSTART b0, TCSTF b1 (RO), TSTOP b2 (W), TUNDF b5
//!   ULPTMR1 (+0x0D, 8b)   TMOD, TEDGPL, TCK count source
//!   ULPTMR2 (+0x0E, 8b)   the prescaler in front of the counter
//!   ULPTIOC (+0x10, 8b)   I/O control
//!
//! ULPTCR shares the AGT's AGTCR layout (HUM Ch 25.2.1 p 1190, mirroring
//! Ch 24.2.6 p 1175), so a TCSTF poll and a TUNDF poll both read real state.
//!
//! Ported from board_periph_ulpt.c on dev, with three departures, all of them
//! places where firmware that misbehaves on the bench passes there.
//!
//! One: dev drops TSTOP on the floor. Its ULPTCR write keeps the TSTART bit
//! and nothing else, so the forced stop the driver issues as TSTART|TSTOP
//! (0x05) leaves the channel running there and stops it on silicon: the
//! emulator keeps waking a part the firmware believes it parked. Here TSTOP
//! wins over TSTART in the same write, clears TCSTF, and holds the count.
//!
//! Two: dev raises the underflow event on the RISING EDGE of TUNDF only, so a
//! periodic image that never clears the flag gets exactly one wake there and
//! wakes every period on the bench: the run hangs in the emulator and the
//! failure looks like the ISR, not the flag. The interrupt is requested at
//! every underflow here, and TUNDF is separately sticky until written zero.
//!
//! Three: dev steps every channel by one constant per chunk whatever the mode
//! registers say, so shortening or lengthening the configured period changes
//! nothing. There is no absolute time here either, but ULPTMR2's prescaler is
//! at least ORDERED: the step is scaled down by the selected divider, so a
//! slower configured source really does underflow less often.
const std = @import("std");

const periph = @import("registry.zig");

/// ULPT geometry (ra8_ulpt_regs.h; HUM Ch 25.1 p 1187).
pub const win_base: u32 = 0x4022_0000;
pub const stride: u32 = 0x100;
pub const channels: usize = 2;
pub const win_span: u32 = stride * channels;

pub const off = struct {
    pub const cnt: u32 = 0x00;
    pub const cma: u32 = 0x04;
    pub const cmb: u32 = 0x08;
    pub const cr: u32 = 0x0C;
    pub const mr1: u32 = 0x0D;
    pub const mr2: u32 = 0x0E;
    pub const mr3: u32 = 0x0F;
    pub const ioc: u32 = 0x10;
};

/// ULPTCR (HUM Ch 25.2.1 p 1190). TSTART is RW, TCSTF read-only, TSTOP
/// write-only, TUNDF write-ZERO-to-clear like the watchdog's status flags.
pub const control = struct {
    pub const tstart: u8 = 0x01;
    pub const tcstf: u8 = 0x02;
    pub const tstop: u8 = 0x04;
    pub const tundf: u8 = 0x20;
};

/// ULPTMR2 (HUM Ch 25.2.3 p 1192): the low-order field selects the divider in
/// front of the counter. Ordered, not calibrated: what matters is that a
/// bigger divider counts slower.
pub const mode2 = struct {
    pub const divider: u8 = 0x07;
};

/// The events channel 0 can raise (RA8D2 ELC signal table). ULPT1 has no
/// distinct event in this codebase and no image drives it, so only channel 0
/// raises anything.
pub const event = struct {
    pub const underflow: u16 = 0x080;
};

/// Counter ticks one run-loop chunk stands for, before the ULPTMR2 divider.
/// Sized above the largest period the deep-idle images load (0x8000) so an
/// armed channel underflows on its first idle tick: the emulator fast
/// forwards a standby WFI one tick at a time, and the underflow has to land
/// inside that single tick to be the source that cancels standby.
pub const ticks_per_chunk: u32 = 0x4_0000;

/// At most one event is due per boundary, from channel 0.
pub const Due = std.BoundedArray(u16, 1);

/// One channel: a reloading down-counter plus its mode and status bytes.
pub const Channel = struct {
    counter: u32 = 0,
    reload: u32 = 0,
    cmpa: u32 = 0,
    cmpb: u32 = 0,
    cr: u8 = 0,
    mr1: u8 = 0,
    mr2: u8 = 0,
    mr3: u8 = 0,
    ioc: u8 = 0,
    /// Underflows reached, which is also the number of events raised.
    underflows: u32 = 0,
    /// Forced stops taken through TSTOP, the bit dev discards.
    forced_stops: u32 = 0,

    pub fn running(self: Channel) bool {
        return self.cr & control.tstart != 0;
    }

    /// The ULPTMR2 divider, as a power of two. A count source this model does
    /// not know still divides by something ordered rather than by one.
    pub fn divider(self: Channel) u32 {
        return @as(u32, 1) << @intCast(self.mr2 & mode2.divider);
    }

    /// One chunk of counting. Returns true when this chunk underflowed, which
    /// is one interrupt request on silicon whatever TUNDF already reads.
    pub fn tick(self: *Channel) bool {
        if (!self.running()) return false;
        const step = @max(1, ticks_per_chunk / self.divider());
        if (self.counter >= step) {
            // Reaching exactly zero is not an underflow yet: the borrow
            // happens on the next decrement past it. dev's port takes the
            // underflow branch here and then wraps `step - counter - 1`
            // through zero, which lands the counter on a junk reload.
            self.counter -= step;
            return false;
        }
        // Periodic: reload and carry the overshoot, so a period shorter than
        // one chunk still lands on a sane count rather than wrapping.
        const span = @as(u64, self.reload) + 1;
        const deficit = step - self.counter;
        self.counter = self.reload - @as(u32, @intCast((deficit - 1) % span));
        self.cr |= control.tundf;
        self.underflows +%= 1;
        return true;
    }

    /// TSTOP beats TSTART in the same write: the driver stops a channel with
    /// both bits set, and silicon takes the stop. TCSTF follows the state the
    /// write leaves, and TUNDF only survives a write that set it.
    fn writeControl(self: *Channel, value: u8) void {
        const keep = self.cr & value & control.tundf;
        if (value & control.tstop != 0) {
            if (self.running()) self.forced_stops +%= 1;
            self.cr = keep;
            return;
        }
        const start = value & control.tstart;
        self.cr = start | (if (start != 0) control.tcstf else 0) | keep;
    }
};

pub const Ulpt = struct {
    channels: [channels]Channel = @splat(.{}),
    /// Channel 0 underflows that have not been handed to the event path yet.
    pending: u32 = 0,
    /// Reads and writes of ULPTCMA/ULPTCMB. Compare match is not modelled,
    /// so an image driving it is told rather than quietly given nothing.
    compare_touches: u32 = 0,

    pub fn init() Ulpt {
        return .{};
    }

    /// The chunk boundary. Every underflow is an interrupt request, so they
    /// are counted rather than collapsed into a flag edge.
    pub fn tick(self: *Ulpt) void {
        for (&self.channels, 0..) |*channel, index| {
            if (channel.tick() and index == 0) self.pending +%= 1;
        }
    }

    /// One event per boundary at most. A backlog stays pending and drains on
    /// later boundaries instead of being dropped.
    pub fn dueEvents(self: *Ulpt) Due {
        var due = Due{};
        if (self.pending == 0) return due;
        self.pending -= 1;
        due.appendAssumeCapacity(event.underflow);
        return due;
    }

    pub fn quiet(self: *const Ulpt) bool {
        for (self.channels) |channel| {
            if (channel.underflows != 0 or channel.running()) return false;
        }
        return self.compare_touches == 0;
    }

    pub fn read(self: *Ulpt, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        const index = offset / stride;
        if (index >= channels) return 0;
        const channel = &self.channels[index];
        const local = offset % stride;
        const cell = self.cellValue(channel, local);
        const lane = local - cellBase(local);
        return extract(cell, lane, width);
    }

    pub fn write(self: *Ulpt, address: u32, width: u3, value: u32) void {
        _ = width;
        const offset = address -% win_base;
        const index = offset / stride;
        if (index >= channels) return;
        const channel = &self.channels[index];
        switch (cellBase(offset % stride)) {
            off.cnt => {
                // A write seeds both the live count and the period the
                // counter reloads from (ra8_ulpt_start writes one value).
                channel.counter = value;
                channel.reload = value;
            },
            off.cma => {
                channel.cmpa = value;
                self.compare_touches +%= 1;
            },
            off.cmb => {
                channel.cmpb = value;
                self.compare_touches +%= 1;
            },
            off.cr => channel.writeControl(@truncate(value)),
            off.mr1 => channel.mr1 = @truncate(value),
            off.mr2 => channel.mr2 = @truncate(value),
            off.mr3 => channel.mr3 = @truncate(value),
            off.ioc => channel.ioc = @truncate(value),
            else => {},
        }
    }

    fn cellValue(self: *Ulpt, channel: *const Channel, local: u32) u32 {
        return switch (cellBase(local)) {
            off.cnt => channel.counter,
            off.cma => blk: {
                self.compare_touches +%= 1;
                break :blk channel.cmpa;
            },
            off.cmb => blk: {
                self.compare_touches +%= 1;
                break :blk channel.cmpb;
            },
            off.cr => channel.cr,
            off.mr1 => channel.mr1,
            off.mr2 => channel.mr2,
            off.mr3 => channel.mr3,
            off.ioc => channel.ioc,
            else => 0,
        };
    }

    pub fn block(self: *Ulpt) periph.Block {
        return .{
            .name = "ULPT",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

/// Which register cell an offset lands in. The three 32-bit cells cover four
/// bytes each; everything above them is one byte of its own.
fn cellBase(local: u32) u32 {
    if (local < off.cma) return off.cnt;
    if (local < off.cmb) return off.cma;
    if (local < off.cr) return off.cmb;
    return local;
}

/// The bytes of `cell` an access of `width` starting at byte `lane` sees.
fn extract(cell: u32, lane: u32, width: u3) u32 {
    var value: u32 = 0;
    var i: u32 = 0;
    while (i < width) : (i += 1) {
        const byte = lane + i;
        if (byte >= @sizeOf(u32)) break;
        value |= ((cell >> @intCast(byte * 8)) & 0xFF) << @intCast(i * 8);
    }
    return value;
}

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Ulpt = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Ulpt = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
