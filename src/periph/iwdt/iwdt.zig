//! IWDT: the watchdog OFS0 starts, that software cannot stop, and that only
//! the two-byte sequence keeps alive.
//!
//! The Independent Watchdog Timer at 0x4020_2200 (HUM Ch 28, FSP
//! R_IWDT_BASE) is a 14-bit down-counter on its own ~15 kHz oscillator,
//! outside the CPU clock tree, so it survives a MOCO or HOCO failure that
//! stops WDT0. Its period, window and reset-versus-NMI choice live in the
//! OFS0 option-setting register rather than in these registers: on the RA8D2
//! there is no register-start mode, and IWDTCR / IWDTRCR / IWDTCSTPR are
//! write-locked once the boot ROM has armed the timer. The runtime surface
//! is what `ra8_iwdt.c` uses: refresh, read the counter, read and clear the
//! status.
//!
//! Nothing answered here before this file; the window fell through to the
//! sparse register file, which keeps whatever it is handed. That made two
//! real firmware paths pass in the model and fail on the bench.
//!
//! One: a single write to IWDTRR looked like a refresh. It is not one; the
//! sequence rule lives in iwdt_refresh.zig.
//!
//! Two: IWDTSR.CNTVAL never moved, so `iwdt_demo`, which refreshes only when
//! the counter has fallen inside its window, waits for a value that a cell
//! will never produce and burns its whole budget. The counter counts here,
//! and iwdt_status.zig keeps it read-only against the driver's own status
//! clear, which writes the counter bits back.
//!
//! What is deliberately NOT modelled. The IWDTCR TOPS and CKS encodings are
//! not written down in either tree (the header gives their bit positions and
//! says OFS0 is the effective control surface), so no period table is
//! invented: the counter runs the full 14-bit range and the fields ride in
//! the register. `counts_per_tick` below is an emulator-time choice in the
//! same spirit as wdt.zig's, not a silicon number. IWDTCSTPR.SLCSTP halts
//! the counter in Sleep, and Sleep is not modelled, so it rides too.
const iwdt_refresh = @import("iwdt_refresh.zig");
const iwdt_status = @import("iwdt_status.zig");
const periph = @import("../registry.zig");

pub const refresh = iwdt_refresh;
pub const status = iwdt_status;

/// IWDT geometry (ra8_iwdt_regs.h, r_iwdt_regs_t; HUM Ch 28.2 p 1273).
pub const win_base: u32 = 0x4020_2200;
pub const win_span: u32 = 0x0C;

pub const off = struct {
    pub const rr: u32 = 0x00;
    pub const cr: u32 = 0x02;
    pub const sr: u32 = 0x04;
    pub const rcr: u32 = 0x06;
    pub const cstpr: u32 = 0x08;
};

/// IWDTCR fields (HUM Ch 28.2.3 p 1276). Held, never acted on: the
/// encodings behind them are not in this tree and OFS0 owns the period.
pub const control = struct {
    pub const tops: u16 = 0x0003;
    pub const cks: u16 = 0x00F0;
    pub const rpes: u16 = 0x0300;
    pub const rpss: u16 = 0x3000;
};

/// IWDTRCR (HUM Ch 28.2.4 p 1277): what an underflow does.
pub const reset_control = struct {
    /// RSTIRQS, bit 7: 1 = reset the part, 0 = NMI.
    pub const rstirqs: u8 = 0x80;
};

/// IWDTCSTPR (HUM Ch 28.2.5 p 1278).
pub const count_stop = struct {
    /// SLCSTP, bit 7: halt the counter in Sleep. Sleep is not modelled.
    pub const slcstp: u8 = 0x80;
};

/// The counter's full reload: its own width, since no period table exists
/// here to pick a shorter one.
pub const full_scale: u16 = iwdt_status.field.cntval;

/// How far the counter falls at one run-loop boundary. Chosen so the full
/// range is crossed in sixteen boundaries, well inside a normal run budget:
/// firmware waits on this counter by polling it, and a rate the run cannot
/// cross is a wait that never ends, which is the bug this file exists to
/// stop modelling. An emulator-time number in the same spirit as wdt.zig's,
/// not a silicon one: the real period comes from OFS0 and IWDTCLK.
pub const counts_per_tick: u16 = 1024;

pub const Iwdt = struct {
    iwdtcr: u16 = 0,
    iwdtrcr: u8 = 0,
    iwdtcstpr: u8 = 0,
    sequence: iwdt_refresh.Sequence = .{},
    counter: u16 = full_scale,
    /// The counter runs once a refresh has arrived. On silicon OFS0 starts
    /// it at reset; option memory is not read here, and a blank one leaves
    /// IWDTSTRT set, which is the stopped selection.
    armed: bool = false,
    flags: u16 = 0,
    /// Completed two-byte sequences that reloaded the counter.
    refreshes: u32 = 0,
    /// Writes to IWDTRR that were not part of a sequence and did nothing.
    dropped: u32 = 0,
    /// Times the counter reached zero.
    underflows: u32 = 0,
    /// Underflows that asked for an NMI rather than a reset, which this
    /// model has nowhere to deliver.
    nmis: u32 = 0,
    /// Set when an underflow asked for a reset in RSTIRQS mode. The board
    /// takes it and hands it to the reset unit.
    reset_requested: bool = false,
    /// Stores to IWDTSR that wrote a one at a standing flag, clearing
    /// nothing.
    bad_acks: u32 = 0,
    /// Stores to IWDTSR that carried counter bits, which never land.
    frozen_writes: u32 = 0,

    pub fn init() Iwdt {
        return .{};
    }

    pub fn quiet(self: *const Iwdt) bool {
        return !self.armed and self.refreshes == 0 and self.dropped == 0 and
            self.flags == 0 and self.bad_acks == 0 and self.frozen_writes == 0;
    }

    /// One run-loop chunk of counting. The counter cannot be stopped by
    /// software, so it reloads and keeps going past an underflow: on silicon
    /// the reset would have ended the run, and here the cause is latched and
    /// the run carries on.
    pub fn tick(self: *Iwdt) void {
        if (!self.armed) return;
        if (self.counter > counts_per_tick) {
            self.counter -= counts_per_tick;
            return;
        }
        self.counter = full_scale;
        self.underflows +%= 1;
        self.flags |= iwdt_status.field.undff;
        if (self.iwdtrcr & reset_control.rstirqs != 0) {
            self.reset_requested = true;
        } else {
            self.nmis +%= 1;
        }
    }

    fn refreshWrite(self: *Iwdt, value: u8) void {
        switch (self.sequence.accept(value)) {
            .reloaded => {
                self.armed = true;
                self.counter = full_scale;
                self.refreshes +%= 1;
            },
            .primed => {},
            .ignored => self.dropped +%= 1,
        }
    }

    fn ackWrite(self: *Iwdt, written: u16) void {
        if (iwdt_status.refused(self.flags, written)) self.bad_acks +%= 1;
        if (iwdt_status.carriesCount(written)) self.frozen_writes +%= 1;
        self.flags = iwdt_status.ack(self.flags, written);
    }

    pub fn read(self: *Iwdt, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        const word: u16 = switch (offset & ~@as(u32, 1)) {
            off.rr => @intFromBool(self.sequence.pending()) * iwdt_refresh.byte.second,
            off.cr => self.iwdtcr,
            off.sr => iwdt_status.value(self.counter, self.flags),
            off.rcr => self.iwdtrcr,
            off.cstpr => self.iwdtcstpr,
            else => 0,
        };
        if (width >= 2 and offset & 1 == 0) return word;
        const shift: u4 = @intCast((offset & 1) * 8);
        return (@as(u32, word) >> shift) & 0xFF;
    }

    pub fn write(self: *Iwdt, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        switch (offset & ~@as(u32, 1)) {
            off.rr => self.refreshWrite(@truncate(value)),
            off.cr => self.iwdtcr = merge(self.iwdtcr, offset, width, value),
            off.sr => self.ackWrite(merge(iwdt_status.value(self.counter, self.flags), offset, width, value)),
            off.rcr => self.iwdtrcr = @truncate(merge(self.iwdtrcr, offset, width, value)),
            off.cstpr => self.iwdtcstpr = @truncate(merge(self.iwdtcstpr, offset, width, value)),
            else => {},
        }
    }

    pub fn block(self: *Iwdt) periph.Block {
        return .{
            .name = "IWDT",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

/// A halfword store carries the whole register; a byte store replaces one
/// half of it and leaves the other standing.
fn merge(current: u16, offset: u32, width: u3, value: u32) u16 {
    if (width >= 2 and offset & 1 == 0) return @truncate(value);
    const shift: u4 = @intCast((offset & 1) * 8);
    const keep: u16 = if (shift == 0) 0xFF00 else 0x00FF;
    return (current & keep) | (@as(u16, @truncate(value & 0xFF)) << shift);
}

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Iwdt = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Iwdt = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
