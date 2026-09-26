//! GPT: the PWM timer, with a period that wraps and a count that stays inside it.
//!
//! Fourteen channels of a 32-bit saw up-counter at 0x4032_2000
//! (ra8_gpt_regs.h). Firmware loads GTPR, starts the channel through GTSTR
//! or GTCR.CST, and then either samples GTCNT to prove the timer is moving or
//! waits on the GPT0 overflow interrupt. Both need a count that really
//! advances, so the channel carries live state rather than a shadow.
//!
//!   GTSTR (+0x04)  software start, bit 0
//!   GTSTP (+0x08)  software stop, bit 0
//!   GTCLR (+0x0C)  software clear, bit 0
//!   GTCR  (+0x2C)  CST bit 0 gates the count
//!   GTST  (+0x3C)  status; TCFPO bit 6 is the overflow
//!   GTCNT (+0x48)  the counter
//!   GTPR  (+0x64)  the period the counter wraps at
//!
//! Ported from board_periph_timer.c on dev, which models the GPT and AGT
//! families together. Three things that model does not do.
//!
//! A FULL-RANGE PERIOD STILL OVERFLOWS. dev tests `(cnt + step) <= period` in
//! 32-bit arithmetic, so a channel with GTPR = 0xFFFF_FFFF has the sum wrap
//! before the comparison and takes the in-range branch every time: TCFPO is
//! never set and the GPT0 event is never raised, so an image using the whole
//! 32-bit range polls a flag that cannot arrive. The sum is computed wide
//! here and a wrap is a wrap at any period.
//!
//! THE COUNT STAYS INSIDE THE PERIOD. dev wraps by subtracting the period
//! once, so a period shorter than one chunk's advance (0x4001) leaves GTCNT
//! reading a value LARGER than GTPR, which silicon cannot produce, and counts
//! one overflow where the hardware had dozens. A driver computing duty from
//! GTCNT against GTPR gets a ratio above one. The advance is reduced modulo
//! the period span here and every wrap inside the chunk is counted.
//!
//! THE WINDOW KEEPS WHAT WAS WRITTEN. dev answers 0 to every offset outside
//! the seven it interprets and drops the stores, so GTIOR, GTSSR, GTBER and
//! the rest read back zero and a driver that verifies its own output setup
//! fails on the readback. Everything uninterpreted is shadowed per channel,
//! and every register takes a narrow store on its own byte lane instead of
//! dev's whole-word assignment, where a halfword store to the low half of
//! GTPR wrote the period and a store to the high half vanished.
//!
//! KEPT FROM DEV DELIBERATELY: GTPR = 0 counts to 0xFFFF rather than standing
//! still, so a channel started before its period is loaded still moves;
//! GTST clears by writing the value back with the target bits zero, so
//! firmware can only clear a flag, never raise one; and only channel 0 raises
//! an event, because GPT0's overflow is the one number this tree carries.
//!
//! ONE EVENT PER BOUNDARY: several wraps inside one chunk are one interrupt
//! here. The count of them is reported, but they are not stacked into a
//! backlog that would fire long after the counter moved on.
//!
//! NOT MODELLED, AND NOT GUESSED: compare match, so GTST.TCFA stays clear
//! (dev names it and never raises it either, and no header in this tree gives
//! GTCCRA's offset); the count direction and buffer registers, so every
//! channel counts up in saw mode; the write-protection register; and the
//! per-source interrupt enables, so channel 0's overflow always raises.
const std = @import("std");

const periph = @import("registry.zig");

/// GPT geometry (ra8_gpt_regs.h).
pub const win_base: u32 = 0x4032_2000;
pub const stride: u32 = 0x100;
pub const channels: usize = 14;
pub const win_span: u32 = stride * @as(u32, channels);

pub const off = struct {
    pub const gtstr: u32 = 0x04;
    pub const gtstp: u32 = 0x08;
    pub const gtclr: u32 = 0x0C;
    pub const gtcr: u32 = 0x2C;
    pub const gtst: u32 = 0x3C;
    pub const gtcnt: u32 = 0x48;
    pub const gtpr: u32 = 0x64;
};

/// GTCR: the count-start bit.
pub const control = struct {
    pub const cst: u32 = 0x0000_0001;
};

/// GTST: the status bits dev's enumeration names.
pub const status = struct {
    pub const tcfa: u32 = 0x0000_0001;
    pub const tcfpo: u32 = 0x0000_0040;
    pub const tcfpu: u32 = 0x0000_0080;
};

/// GPT0's counter-overflow event (RA8D2 ELC signal table; FSP bsp_elc.h).
pub const event = struct {
    pub const gpt0_overflow: u16 = 0x0C1;
};

/// The advance one chunk boundary stands for, carried from dev with its
/// reason: it is ODD, so it is coprime to the 2^16 and 2^32 saw periods the
/// drivers use. A power-of-two advance divides those periods evenly, GTCNT
/// then visits a handful of values, and a demo sampling on a power-of-two
/// millisecond cadence reads the same count every time and calls the timer
/// wedged.
pub const step_per_tick: u32 = 0x0000_4001;

/// GTPR = 0 counts to the 16-bit wrap, as dev does.
pub const default_period: u32 = 0xFFFF;

/// At most one event per boundary, from channel 0.
pub const Due = std.BoundedArray(u16, 1);

/// One channel: the counter, its period, the control and status words, and a
/// shadow for every register this model does not interpret.
pub const Channel = struct {
    cnt: u32 = 0,
    period: u32 = 0,
    cr: u32 = 0,
    st: u32 = 0,
    shadow: [stride]u8 = @splat(0),
    overflows: u32 = 0,

    pub fn running(self: Channel) bool {
        return self.cr & control.cst != 0;
    }

    /// The period a zero GTPR stands for.
    pub fn periodOrDefault(self: Channel) u32 {
        return if (self.period == 0) default_period else self.period;
    }

    /// One chunk of counting. Returns how many times the count passed the
    /// period, which is zero for a stopped or in-range channel.
    pub fn tick(self: *Channel) u32 {
        if (!self.running()) return 0;
        const period = self.periodOrDefault();
        const span = @as(u64, period) + 1;
        const next = @as(u64, self.cnt) + step_per_tick;
        if (next <= period) {
            self.cnt = @intCast(next);
            return 0;
        }
        const wraps: u32 = @intCast(next / span);
        self.cnt = @intCast(next % span);
        self.st |= status.tcfpo;
        self.overflows +%= wraps;
        return wraps;
    }

    fn readByte(self: *const Channel, local: u32) u8 {
        return switch (cellOf(local)) {
            off.gtcnt => lane(self.cnt, local - off.gtcnt),
            off.gtpr => lane(self.period, local - off.gtpr),
            off.gtcr => lane(self.cr, local - off.gtcr),
            off.gtst => lane(self.st, local - off.gtst),
            else => self.shadow[local],
        };
    }

    fn writeByte(self: *Channel, local: u32, byte: u8) void {
        switch (cellOf(local)) {
            off.gtcnt => self.cnt = merge(self.cnt, local - off.gtcnt, byte),
            off.gtpr => self.period = merge(self.period, local - off.gtpr, byte),
            off.gtcr => self.cr = merge(self.cr, local - off.gtcr, byte),
            // GTST is cleared by writing the word back with the target bits
            // zero, so a store can only take bits away.
            off.gtst => self.st &= merge(self.st, local - off.gtst, byte),
            off.gtstr => self.request(local == off.gtstr, byte, .start),
            off.gtstp => self.request(local == off.gtstp, byte, .stop),
            off.gtclr => self.request(local == off.gtclr, byte, .clear),
            else => self.shadow[local] = byte,
        }
    }

    const Request = enum { start, stop, clear };

    /// The three action registers act on bit 0 of their low byte; a store to
    /// any other lane of them changes nothing, which is what the hardware
    /// does with the channel-select bits this model has no channels for.
    fn request(self: *Channel, low_lane: bool, byte: u8, what: Request) void {
        if (!low_lane or byte & 1 == 0) return;
        switch (what) {
            .start => self.cr |= control.cst,
            .stop => self.cr &= ~control.cst,
            .clear => self.cnt = 0,
        }
    }

    pub fn quiet(self: Channel) bool {
        return self.overflows == 0 and !self.running();
    }
};

/// The register a byte offset belongs to, so a narrow store lands on the
/// right word instead of falling through to the shadow.
fn cellOf(local: u32) u32 {
    const cells = [_]u32{
        off.gtstr, off.gtstp, off.gtclr, off.gtcr,
        off.gtst,  off.gtcnt, off.gtpr,
    };
    for (cells) |cell| {
        if (local >= cell and local < cell + 4) return cell;
    }
    return local;
}

fn lane(value: u32, index: u32) u8 {
    return @truncate(value >> @intCast(index * 8));
}

fn merge(value: u32, index: u32, byte: u8) u32 {
    const shift: u5 = @intCast(index * 8);
    const mask = ~(@as(u32, 0xFF) << shift);
    return (value & mask) | (@as(u32, byte) << shift);
}

pub const Gpt = struct {
    channels: [channels]Channel = @splat(.{}),
    /// Whether channel 0 wrapped this boundary.
    pending: bool = false,

    pub fn init() Gpt {
        return .{};
    }

    pub fn tick(self: *Gpt) void {
        for (&self.channels, 0..) |*channel, index| {
            if (channel.tick() != 0 and index == 0) self.pending = true;
        }
    }

    pub fn dueEvents(self: *Gpt) Due {
        var due = Due{};
        if (!self.pending) return due;
        self.pending = false;
        due.appendAssumeCapacity(event.gpt0_overflow);
        return due;
    }

    pub fn quiet(self: *const Gpt) bool {
        for (self.channels) |channel| {
            if (!channel.quiet()) return false;
        }
        return true;
    }

    pub fn read(self: *Gpt, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        if (offset >= win_span) return 0;
        const channel = &self.channels[offset / stride];
        const local = offset % stride;
        var value: u32 = 0;
        var index: u32 = 0;
        while (index < width and local + index < stride) : (index += 1) {
            const shift: u5 = @intCast(index * 8);
            value |= @as(u32, channel.readByte(local + index)) << shift;
        }
        return value;
    }

    pub fn write(self: *Gpt, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        if (offset >= win_span) return;
        const channel = &self.channels[offset / stride];
        const local = offset % stride;
        var index: u32 = 0;
        while (index < width and local + index < stride) : (index += 1) {
            const shift: u5 = @intCast(index * 8);
            channel.writeByte(local + index, @truncate(value >> shift));
        }
    }

    pub fn block(self: *Gpt) periph.Block {
        return .{
            .name = "GPT",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Gpt = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Gpt = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
