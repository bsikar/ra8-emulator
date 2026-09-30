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
//! THE COUNT SOURCE lives in src/periph/gpt_clock.zig: GTCR's TPCS field
//! picks the divider a channel counts at, so a channel slowed to PCLKD/1024
//! really is a thousand times slower than an undivided one instead of every
//! channel counting at the same rate.
//!
//! COMPARE MATCH lives in src/periph/gpt_compare.zig: GTCCRA (+0x4C) and
//! GTCCRB (+0x50) are compared against the count rather than shadowed, and a
//! crossing raises GTST.TCFA or TCFB. Everything that file does not claim is
//! still shadowed.
//!
//! THE COUNTER MODE lives in src/periph/gpt_mode.zig: GTCR's MD field picks
//! the shape a channel counts in, so a triangle channel rises to the period
//! and falls back to zero instead of sawing, and a one-shot channel stops
//! itself at the period instead of wrapping forever.
//!
//! THE BUFFERED COMPARE lives in src/periph/gpt_buffer.zig: GTBER (+0x40)
//! says whether a channel reloads GTCCRA and GTCCRB from their buffer
//! registers at the end of a cycle, so a duty the HAL parks through
//! `ra8_gpt_duty_cycle_set` arrives on the next cycle instead of never
//! arriving at all. This file's note used to say a buffered duty took effect
//! at once; it did not take effect, because nothing read the buffer.
//!
//! THE WRITE PROTECTION lives in src/periph/gpt_lock.zig: GTWP (+0x00)
//! carries a password in its upper byte and WP in bit 0, and the HAL
//! brackets every channel it touches between the two keys, so a channel the
//! HAL has finished with is shut and a store that skips the key is dropped
//! instead of landing.
//!
//! NOT MODELLED, AND NOT GUESSED: the per-source interrupt enables in
//! GTINTAD, so channel 0's overflow always raises and a compare match never
//! does.
const std = @import("std");

const buf = @import("gpt_buffer.zig");
const clk = @import("gpt_clock.zig");
const compare = @import("gpt_compare.zig");
const lk = @import("gpt_lock.zig");
const win = @import("gpt_window.zig");
const md = @import("gpt_mode.zig");
const prd = @import("gpt_period.zig");
const sync = @import("gpt_sync.zig");
const periph = @import("registry.zig");

/// The compare pair, reached as `gpt.match` the way the other split blocks in
/// this tree re-export their halves.
pub const match = compare;

/// The count source, reached as `gpt.clock` the same way.
pub const clock = clk;

/// The counter mode, reached as `gpt.mode`.
pub const mode = md;

/// The compare buffers, reached as `gpt.buffers`.
pub const buffers = buf;

/// The write protection, reached as `gpt.protection`.
pub const protection = lk;

/// The channel window's addressing, reached as `gpt.window`.
pub const window = win;

/// GPT geometry (ra8_gpt_regs.h).
pub const win_base: u32 = 0x4032_2000;
pub const stride: u32 = 0x100;
pub const channels: usize = 14;
pub const win_span: u32 = stride * @as(u32, channels);

/// Where each register this model interprets sits in a channel, re-exported
/// from the window so callers reach it as `gpt.off` the way they always did.
pub const off = win.off;

/// GTPR and its buffer GTPBR live in src/periph/gpt_period.zig.
pub const periods = prd;

/// GTCR: the count-start bit. The rest of the register's fields live in
/// gpt_clock.zig, which reads the prescaler out of it.
pub const control = struct {
    pub const cst: u32 = clk.field.cst;
};

/// GTST: the status bits dev's enumeration names.
pub const status = struct {
    pub const tcfa: u32 = compare.flag.tcfa;
    pub const tcfb: u32 = compare.flag.tcfb;
    pub const tcfpo: u32 = 0x0000_0040;
    pub const tcfpu: u32 = 0x0000_0080;
};

/// GPT0's counter-overflow event (RA8D2 ELC signal table; FSP bsp_elc.h).
pub const event = struct {
    pub const gpt0_overflow: u16 = 0x0C1;
};

/// The advance one chunk boundary stands for at the UNDIVIDED clock, carried
/// from dev with its
/// reason: it is ODD, so it is coprime to the 2^16 and 2^32 saw periods the
/// drivers use. A power-of-two advance divides those periods evenly, GTCNT
/// then visits a handful of values, and a demo sampling on a power-of-two
/// millisecond cadence reads the same count every time and calls the timer
/// wedged.
pub const step_per_tick: u32 = 0x0000_4001;

/// GTPR = 0 counts to the 16-bit wrap, as dev does. The rule lives with the
/// register in gpt_period.zig.
pub const default_period: u32 = prd.default;

/// At most one event per boundary, from channel 0.
pub const Due = std.BoundedArray(u16, 1);

/// One channel: the counter, its period, the control and status words, and a
/// shadow for every register this model does not interpret.
pub const Channel = struct {
    cnt: u32 = 0,
    period: prd.Period = .{},
    cr: u32 = 0,
    st: u32 = 0,
    shadow: [stride]u8 = @splat(0),
    overflows: u32 = 0,
    /// Times a triangle came back to zero. Always zero outside one.
    underflows: u32 = 0,
    /// Which way the count is going. Only a triangle ever sets it false.
    rising: bool = true,
    compares: compare.Pair = .{},
    buffered: buf.Buffers = .{},
    guard: lk.Lock = .{},

    pub fn running(self: Channel) bool {
        return self.cr & control.cst != 0;
    }

    /// The clock this channel counts on, out of GTCR.TPCS.
    pub fn source(self: Channel) clk.Source {
        return clk.sourceOf(self.cr);
    }

    /// The shape this channel counts in, out of GTCR.MD.
    pub fn shape(self: Channel) md.Mode {
        return md.modeOf(self.cr);
    }

    /// The period a zero GTPR stands for.
    pub fn periodOrDefault(self: Channel) u32 {
        return self.period.span();
    }

    /// One chunk of counting, in the shape GTCR.MD selects. Returns how many
    /// times the count reached the period, which is zero for a stopped or
    /// in-range channel.
    pub fn tick(self: *Channel) u32 {
        if (!self.running()) return 0;
        const period = self.periodOrDefault();
        const before = self.cnt;
        const kind = self.shape();
        const moved = md.advance(kind, self.cnt, self.rising, period, clk.step(step_per_tick, self.source()));
        self.cnt = moved.cnt;
        self.rising = moved.rising;
        if (moved.peaks != 0) {
            self.st |= status.tcfpo;
            self.overflows +%= moved.peaks;
        }
        if (moved.troughs != 0) {
            self.st |= status.tcfpu;
            self.underflows +%= moved.troughs;
        }
        if (moved.halted) self.cr &= ~control.cst;
        self.st |= self.matched(kind, before, moved, period);
        if (md.endedCycle(kind, moved)) self.reload();
        return moved.peaks;
    }

    /// Hand the buffered compares over, the way GTBER's single-buffer
    /// selection says to. The chunk's own matches were judged above against
    /// the values that were live while it ran, so a duty arriving here
    /// governs the next cycle and not the one that just finished.
    fn reload(self: *Channel) void {
        if (self.buffered.take(.a)) |value| self.compares.load(.a, value);
        if (self.buffered.take(.b)) |value| self.compares.load(.b, value);
        self.period.reload();
    }

    /// The compare flags this chunk raised. A saw chunk is an up-count and is
    /// described by its wraps; a triangle one may have turned, so it is
    /// described by the span of counts it covered.
    fn matched(self: *Channel, kind: md.Mode, before: u32, moved: md.Step, period: u32) u32 {
        if (!kind.symmetric()) return self.compares.step(before, moved.cnt, moved.peaks);
        const span = md.visited(before, moved, period);
        return self.compares.stepSpan(before, span.lo, span.hi);
    }

    fn readByte(self: *const Channel, local: u32) u8 {
        if (local < lk.off.gtwp + 4) return win.lane(self.guard.value(), local - lk.off.gtwp);
        if (compare.which(local)) |side| {
            const base = if (side == .a) compare.off.gtccra else compare.off.gtccrb;
            return win.lane(self.compares.value(side), local - base);
        }
        if (buf.which(local)) |side| {
            const base = if (side == .a) buf.off.buffer_a else buf.off.buffer_b;
            return win.lane(self.buffered.value(side), local - base);
        }
        if (prd.which(local)) |part| {
            const base = if (part == .live) prd.off.gtpr else prd.off.gtpbr;
            return win.lane(self.period.value(part), local - base);
        }
        return switch (win.cellOf(local)) {
            buf.off.gtber => win.lane(self.buffered.ber, local - buf.off.gtber),
            off.gtcnt => win.lane(self.cnt, local - off.gtcnt),
            off.gtcr => win.lane(self.cr, local - off.gtcr),
            off.gtst => win.lane(self.st, local - off.gtst),
            else => self.shadow[local],
        };
    }

    fn writeByte(self: *Channel, local: u32, byte: u8) void {
        if (compare.which(local)) |side| {
            const base = if (side == .a) compare.off.gtccra else compare.off.gtccrb;
            self.compares.set(side, win.merge(self.compares.value(side), local - base, byte));
            return;
        }
        if (buf.which(local)) |side| {
            const base = if (side == .a) buf.off.buffer_a else buf.off.buffer_b;
            self.buffered.set(side, win.merge(self.buffered.value(side), local - base, byte));
            return;
        }
        if (prd.which(local)) |part| {
            const base = if (part == .live) prd.off.gtpr else prd.off.gtpbr;
            self.period.set(part, win.merge(self.period.value(part), local - base, byte));
            return;
        }
        switch (win.cellOf(local)) {
            buf.off.gtber => self.buffered.ber = win.merge(self.buffered.ber, local - buf.off.gtber, byte),
            off.gtcnt => self.cnt = win.merge(self.cnt, local - off.gtcnt, byte),
            off.gtcr => self.cr = win.merge(self.cr, local - off.gtcr, byte),
            // GTST is cleared by writing the word back with the target bits
            // zero, so a store can only take bits away.
            off.gtst => self.st &= win.merge(self.st, local - off.gtst, byte),
            // GTSTR, GTSTP and GTCLR name channels by bit, so the bank takes
            // them whole before an access is broken into lanes.
            off.gtstr, off.gtstp, off.gtclr => {},
            else => self.shadow[local] = byte,
        }
    }

    pub fn quiet(self: Channel) bool {
        if (!self.compares.quiet() or !self.buffered.quiet() or !self.guard.quiet()) return false;
        return self.overflows == 0 and self.underflows == 0 and !self.running();
    }
};

pub const Gpt = struct {
    channels: [channels]Channel = @splat(.{}),
    /// Whether channel 0 wrapped this boundary.
    pending: bool = false,
    /// What the bank's three action registers did. See gpt_sync.zig.
    sync: sync.Sync = .{},

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
        if (!self.sync.quiet()) return false;
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
        // GTWP takes the whole access at once, so the key is judged on the
        // word the store leaves behind rather than on a byte of it.
        if (local < lk.off.gtwp + 4) {
            channel.guard.store(local - lk.off.gtwp, width, value);
            return;
        }
        // One store, one refusal: the protection turns the access away, not
        // each of its byte lanes.
        if (!channel.guard.admits(local, win.protected(local))) return;
        // The bits are channel-indexed, so the access acts on the channels it
        // names rather than on the window it came through.
        if (sync.which(local)) |action| {
            const bits = sync.carried(local - sync.base(action), width, value);
            sync.dispatch(&self.sync, action, bits, offset / stride, &self.channels);
            return;
        }
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
