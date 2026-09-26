//! WDT0: the window watchdog, so a missed refresh actually times out.
//!
//! The Window Watchdog Timer at 0x4020_2600 (HUM Ch 27) is a down-counter the
//! firmware has to keep reloading. Two things end a run on silicon: letting it
//! reach zero, and refreshing it *too early*. The second is the one that gets
//! missed. The counter has a permitted refresh window, and a reload issued
//! before the window opens is a refresh error, which with WDTRCR.RSTIRQS set
//! resets the part exactly as an underflow does. A watchdog service routine
//! called from a fast loop trips it, and the failure looks like a spontaneous
//! reboot rather than a watchdog fault.
//!
//!   WDTRR  (+0x00, 8b)   refresh register: 0x00 then 0xFF reloads the counter
//!   WDTCR  (+0x02, 16b)  TOPS timeout, CKS divider, RPSS/RPES window edges
//!   WDTSR  (+0x04, 16b)  CNTVAL[13:0] live counter, UNDFF[14], REFEF[15]
//!   WDTRCR (+0x06, 8b)   RSTIRQS: 1 = reset on underflow, 0 = NMI/IRQ
//!
//! Ported from board_periph_wdt.c on dev, with three departures from it, all
//! of them places where firmware that fails on the bench passes there.
//!
//! One: dev models no refresh window at all, so a refresh is always accepted
//! ("the model does not synthesise the refresh-error path"). Here the counter
//! position is checked against RPSS/RPES and an early reload latches REFEF and
//! refuses to reload, which is what the hardware does.
//!
//! Two: dev clears UNDFF on the next refresh, so a driver that never reads the
//! flag still sees a clean status register. HUM Ch 27.2.3 p 1076 gives both
//! flags one way down, a write of ZERO to the bit, so they are sticky here and
//! only a write-zero takes them off. Write-one clears nothing, the same
//! opposite polarity that bit the ICU (IR) and the voltage monitors (DET).
//!
//! Three: dev maps every timeout to one constant number of chunks, so a
//! firmware that shortens its timeout period sees no change and a firmware
//! that lengthens it sees no change either. The emulator has no watchdog clock
//! and absolute time is not modelled, but TOPS and CKS are at least ordered
//! here: the reload is the configured cycle count scaled down to ticks, so a
//! longer configured timeout takes proportionally longer to trip.
const periph = @import("registry.zig");

/// WDT0 geometry (ra8_wdt_regs.h, r_wdt_regs_t; HUM Ch 27.2 p 1070).
pub const win_base: u32 = 0x4020_2600;
pub const win_span: u32 = 0x10;

pub const off = struct {
    pub const wdtrr: u32 = 0x00;
    pub const wdtcr: u32 = 0x02;
    pub const wdtsr: u32 = 0x04;
    pub const wdtrcr: u32 = 0x06;
};

/// The refresh register takes a two-byte sequence, not a value.
pub const refresh = struct {
    pub const first: u8 = 0x00;
    pub const second: u8 = 0xFF;
};

/// WDTCR fields (HUM Ch 27.2.2 p 1072).
pub const control = struct {
    pub const tops: u16 = 0x0003;
    pub const cks: u16 = 0x00F0;
    pub const cks_shift: u4 = 4;
    pub const rpes: u16 = 0x0300;
    pub const rpes_shift: u4 = 8;
    pub const rpss: u16 = 0x3000;
    pub const rpss_shift: u4 = 12;
};

/// WDTSR fields (HUM Ch 27.2.3 p 1076). Both flags are write-ZERO-to-clear.
pub const status = struct {
    pub const cntval: u16 = 0x3FFF;
    pub const undff: u16 = 0x4000;
    pub const refef: u16 = 0x8000;
    pub const flags: u16 = undff | refef;
};

/// WDTRCR (HUM Ch 27.2.4 p 1077): what an underflow or refresh error does.
pub const reset_control = struct {
    pub const rstirqs: u8 = 0x80;
};

/// TOPS[1:0]: the counter's full reload, in watchdog cycles.
pub const tops_cycles = [4]u32{ 1024, 4096, 8192, 16384 };

/// CKS[3:0]: the PCLKB divider in front of the counter. The encodings this
/// part leaves reserved divide by 1, which is what an unprogrammed CKS reads.
pub const cks_divider = [16]u32{ 1, 1, 1, 1, 16, 32, 64, 1, 256, 512, 2048, 8192, 1, 1, 1, 1 };

/// RPSS[1:0]: where the permitted window opens, as a percentage of the count
/// still to run. 100% means the window is open from the reload.
pub const window_start_percent = [4]u8{ 25, 50, 75, 100 };

/// RPES[1:0]: where the window closes. 0% means it stays open to underflow.
pub const window_end_percent = [4]u8{ 75, 50, 25, 0 };

/// One emulated tick is one run-loop chunk, and this is how many watchdog
/// cycles that stands for. Chosen so the shortest timeout (1024 cycles,
/// divide by 1) still takes several ticks to run out and the longest stays
/// inside a normal run budget.
pub const cycles_per_tick: u32 = 128;

/// The largest reload the counter can hold, so a long timeout saturates
/// instead of wrapping into a short one.
pub const max_ticks: u32 = status.cntval;

pub const Wdt = struct {
    wdtcr: u16 = 0,
    wdtrcr: u8 = 0,
    last_rr: u8 = 0xFF,
    armed: bool = false,
    counter: u32 = 0,
    flags: u16 = 0,
    /// Refreshes that reloaded the counter.
    refreshes: u32 = 0,
    /// Refreshes refused because the window was not open yet.
    early: u32 = 0,
    /// Underflows reached.
    underflows: u32 = 0,
    /// Set once an underflow or refresh error asked for a reset in RSTIRQS
    /// mode. The reset itself belongs to the reset block, which is not ported
    /// yet, so the request is latched and reported rather than performed.
    reset_requested: bool = false,
    /// Acks that cleared nothing because they wrote a one at a flag.
    bad_acks: u32 = 0,

    pub fn init() Wdt {
        return .{};
    }

    pub fn quiet(self: *const Wdt) bool {
        return !self.armed and self.refreshes == 0 and self.flags == 0 and
            self.early == 0 and self.bad_acks == 0;
    }

    /// The full reload for the programmed TOPS and CKS, in ticks.
    pub fn reload(self: *const Wdt) u32 {
        const cycles = tops_cycles[self.wdtcr & control.tops];
        const divider = cks_divider[(self.wdtcr & control.cks) >> control.cks_shift];
        const ticks = (cycles / cycles_per_tick) * divider;
        return @min(@max(ticks, 1), max_ticks);
    }

    /// True while the counter sits inside the refresh window RPSS/RPES marks
    /// out. Both edges are percentages of the reload, measured down from it,
    /// so the window opens once the counter has fallen past RPSS and closes
    /// when it falls past RPES.
    pub fn windowOpen(self: *const Wdt) bool {
        const full = self.reload();
        const opens = percentOf(full, window_start_percent[(self.wdtcr & control.rpss) >> control.rpss_shift]);
        const closes = percentOf(full, window_end_percent[(self.wdtcr & control.rpes) >> control.rpes_shift]);
        return self.counter <= opens and self.counter >= closes;
    }

    /// One run-loop chunk of counting. An armed counter that reaches zero
    /// underflows once: the flag latches, a reset is asked for in RSTIRQS
    /// mode, and the counter disarms so it cannot fire again unrefreshed.
    pub fn tick(self: *Wdt) void {
        if (!self.armed) return;
        if (self.counter > 0) {
            self.counter -= 1;
            return;
        }
        self.armed = false;
        self.underflows +%= 1;
        self.flags |= status.undff;
        if (self.wdtrcr & reset_control.rstirqs != 0) self.reset_requested = true;
    }

    /// The 0x00 then 0xFF sequence. The first one arms a stopped counter; any
    /// later one is a reload, and a reload before the window opens is a
    /// refresh error that reloads nothing.
    fn refreshWrite(self: *Wdt, byte: u8) void {
        defer self.last_rr = byte;
        if (self.last_rr != refresh.first or byte != refresh.second) return;
        if (self.armed and !self.windowOpen()) {
            self.early +%= 1;
            self.flags |= status.refef;
            if (self.wdtrcr & reset_control.rstirqs != 0) self.reset_requested = true;
            return;
        }
        self.armed = true;
        self.counter = self.reload();
        self.refreshes +%= 1;
    }

    /// WDTSR takes a write of zero at a flag to clear it. A write of one
    /// leaves it standing, and cannot set it either.
    fn ackWrite(self: *Wdt, value: u16) void {
        const held = self.flags & status.flags;
        const ones = value & held;
        if (ones != 0) self.bad_acks +%= 1;
        self.flags = ones;
    }

    pub fn read(self: *Wdt, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        const word: u16 = switch (offset & ~@as(u32, 1)) {
            off.wdtcr => self.wdtcr,
            off.wdtsr => @as(u16, @intCast(self.counter & status.cntval)) | self.flags,
            off.wdtrcr => self.wdtrcr,
            // WDTRR reads 0 outside a refresh sequence (HUM Ch 27.2.1).
            else => 0,
        };
        if (width >= 2 and offset & 1 == 0) return word;
        const shift: u4 = @intCast((offset & 1) * 8);
        return (@as(u32, word) >> shift) & 0xFF;
    }

    pub fn write(self: *Wdt, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        switch (offset & ~@as(u32, 1)) {
            off.wdtrr => self.refreshWrite(@truncate(value)),
            off.wdtcr => self.wdtcr = self.merge(self.wdtcr, offset, width, value),
            off.wdtsr => self.ackWrite(self.merge(self.flags | @as(u16, @intCast(self.counter & status.cntval)), offset, width, value)),
            off.wdtrcr => self.wdtrcr = @truncate(self.merge(self.wdtrcr, offset, width, value)),
            else => {},
        }
    }

    /// A halfword store carries the whole register; a byte store replaces one
    /// half of it and leaves the other standing.
    fn merge(self: *const Wdt, current: u16, offset: u32, width: u3, value: u32) u16 {
        _ = self;
        if (width >= 2 and offset & 1 == 0) return @truncate(value);
        const shift: u4 = @intCast((offset & 1) * 8);
        const keep: u16 = if (shift == 0) 0xFF00 else 0x00FF;
        return (current & keep) | (@as(u16, @truncate(value & 0xFF)) << shift);
    }

    pub fn block(self: *Wdt) periph.Block {
        return .{
            .name = "WDT0",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn percentOf(full: u32, percent: u8) u32 {
    return @intCast((@as(u64, full) * percent) / 100);
}

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Wdt = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Wdt = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}

/// The WDTCR word for a timeout period, divider and window pair, so firmware
/// and tests say what they mean instead of assembling bit fields by hand.
pub fn controlWord(tops: u2, cks: u4, rpss: u2, rpes: u2) u16 {
    return @as(u16, tops) |
        (@as(u16, cks) << control.cks_shift) |
        (@as(u16, rpes) << control.rpes_shift) |
        (@as(u16, rpss) << control.rpss_shift);
}
