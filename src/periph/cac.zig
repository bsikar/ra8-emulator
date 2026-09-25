//! CAC: the Clock Frequency Accuracy Measurement Circuit, so a clock check ends.
//!
//! The RA8D2 CAC lives at 0x4020_2400 (HUM Ch 10.2, ra8_cac_regs.h) and counts
//! edges of one clock inside a window of another, then says whether the count
//! landed between two firmware-programmed limits. Until now it fell through to
//! the sparse register file, and a sparse cell cannot finish a measurement:
//! CACR0.CFME went in, and the driver then sat on CASTR waiting for MENDF to
//! appear. `ra8_cac.c` polls that flag with no timeout of its own, so on the
//! Zig side a clock check was an endless loop rather than a result. Ported from
//! board_periph_cac.c on dev.
//!
//!   CACR0   (+0x00, 8b)  CFME, the measurement enable
//!   CACR1   (+0x01, 8b)  measurement-clock select, shadowed
//!   CACR2   (+0x02, 8b)  reference-clock select and divider, shadowed
//!   CAICR   (+0x03, 8b)  interrupt enables, plus the three flag-clear strobes
//!   CASTR   (+0x04, 8b)  FERRF, MENDF, OVFF
//!   CAULVR  (+0x06, 16b) upper limit of the acceptable window
//!   CALLVR  (+0x08, 16b) lower limit
//!   CACNTBR (+0x0A, 16b) the latched edge count
//!
//! A measurement here completes the instant CFME goes high: there is no clock
//! to count in an instruction-stepped emulator, so the count reported is the
//! midpoint of the window the firmware asked for. In band by construction, and
//! the driver's own comparison against CAULVR/CALLVR is what gets exercised.
//! The one case that is not in band is a window programmed upside down, and
//! that is reported the way silicon reports it, with FERRF.
const std = @import("std");
const periph = @import("registry.zig");

/// CAC geometry (HUM Ch 10.2). The Non-secure alias is folded onto this base by
/// the bus before anything here sees it.
pub const win_base: u32 = 0x4020_2400;
pub const win_span: u32 = 0x10;

pub const off_cacr0: u32 = 0x00;
pub const off_cacr1: u32 = 0x01;
pub const off_cacr2: u32 = 0x02;
pub const off_caicr: u32 = 0x03;
pub const off_castr: u32 = 0x04;
pub const off_caulvr: u32 = 0x06;
pub const off_callvr: u32 = 0x08;
pub const off_cacntbr: u32 = 0x0A;

/// CACR0.CFME: setting it starts a measurement.
pub const cfme: u8 = 0x01;

/// CASTR flags (HUM Ch 10.2.6). Every one of them is sticky until CAICR
/// clears it.
pub const status = struct {
    pub const ferrf: u8 = 0x01;
    pub const mendf: u8 = 0x02;
    pub const ovff: u8 = 0x04;
    pub const all: u8 = ferrf | mendf | ovff;
};

/// CAICR write-1-to-clear strobes, and the enable bits that read back.
pub const clear = struct {
    pub const ferrfcl: u8 = 0x10;
    pub const mendfcl: u8 = 0x20;
    pub const ovffcl: u8 = 0x40;
    pub const all: u8 = ferrfcl | mendfcl | ovffcl;
    /// FERRIE, MENDIE and OVFIE keep their value; the strobes always read 0.
    pub const enables: u8 = 0x07;
};

/// The unit: two control shadows, the window, the latched count and the flags.
pub const Cac = struct {
    cacr0: u8 = 0,
    cacr1: u8 = 0,
    cacr2: u8 = 0,
    caicr: u8 = 0,
    castr: u8 = 0,
    caulvr: u16 = 0,
    callvr: u16 = 0,
    cacntbr: u16 = 0,
    measurements: u32 = 0,

    pub fn init() Cac {
        return .{};
    }

    /// Untouched units stay out of the end-of-run report.
    pub fn quiet(self: *const Cac) bool {
        return self.measurements == 0;
    }

    pub fn flagSet(self: *const Cac, mask: u8) bool {
        return self.castr & mask == mask;
    }

    /// Run one measurement to completion.
    ///
    /// The count is the midpoint of [CALLVR, CAULVR], so a driver that checks
    /// its own window gets a pass. A window whose lower limit is above its
    /// upper one cannot contain any count, so that measurement ends in FERRF
    /// with the count clamped to the limit the firmware asked for.
    pub fn measure(self: *Cac) void {
        self.measurements +%= 1;
        if (self.callvr > self.caulvr) {
            self.cacntbr = self.caulvr;
            self.castr |= status.ferrf | status.mendf;
            return;
        }
        const sum = @as(u32, self.callvr) + @as(u32, self.caulvr);
        self.cacntbr = @intCast(sum / 2);
        self.castr |= status.mendf;
    }

    pub fn read(self: *Cac, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        return switch (offset) {
            off_cacr0 => self.cacr0,
            off_cacr1 => self.cacr1,
            off_cacr2 => self.cacr2,
            // The clear strobes are write-only: they read back as zero even
            // while the flag they clear is still set.
            off_caicr => self.caicr & clear.enables,
            off_castr => self.castr,
            else => self.readWindow(offset, width),
        };
    }

    /// CAULVR, CALLVR and CACNTBR, each a 16-bit register a driver may reach a
    /// byte at a time.
    fn readWindow(self: *Cac, offset: u32, width: u3) u32 {
        if (offset >= off_caulvr and offset < off_caulvr + 2) {
            return part(self.caulvr, offset - off_caulvr, width);
        }
        if (offset >= off_callvr and offset < off_callvr + 2) {
            return part(self.callvr, offset - off_callvr, width);
        }
        if (offset >= off_cacntbr and offset < off_cacntbr + 2) {
            return part(self.cacntbr, offset - off_cacntbr, width);
        }
        // Nothing else answers in this window. Zero beats the sparse file's
        // alternating stand-in: a poll here is reading a register the hardware
        // has no value for.
        return 0;
    }

    pub fn write(self: *Cac, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        const byte: u8 = @truncate(value);
        switch (offset) {
            off_cacr0 => self.writeCacr0(byte),
            off_cacr1 => self.cacr1 = byte,
            off_cacr2 => self.cacr2 = byte,
            off_caicr => self.writeCaicr(byte),
            // CASTR is read-only. A flag is cleared through CAICR, never by
            // writing the status register, which is the mistake that makes a
            // driver spin on a flag it thinks it cleared.
            off_castr => {},
            else => self.writeWindow(offset, width, value),
        }
    }

    /// CFME rising starts a measurement; CFME falling stops the unit and, on
    /// silicon, leaves the last count in CACNTBR.
    fn writeCacr0(self: *Cac, byte: u8) void {
        const was_running = self.cacr0 & cfme != 0;
        self.cacr0 = byte;
        if (byte & cfme != 0 and !was_running) self.measure();
    }

    fn writeCaicr(self: *Cac, byte: u8) void {
        self.caicr = byte & clear.enables;
        if (byte & clear.ferrfcl != 0) self.castr &= ~status.ferrf;
        if (byte & clear.mendfcl != 0) self.castr &= ~status.mendf;
        if (byte & clear.ovffcl != 0) self.castr &= ~status.ovff;
    }

    fn writeWindow(self: *Cac, offset: u32, width: u3, value: u32) void {
        if (offset >= off_caulvr and offset < off_caulvr + 2) {
            self.caulvr = merge(self.caulvr, offset - off_caulvr, width, value);
            return;
        }
        if (offset >= off_callvr and offset < off_callvr + 2) {
            self.callvr = merge(self.callvr, offset - off_callvr, width, value);
            return;
        }
        // CACNTBR is the counter buffer: the unit writes it, firmware reads it.
    }

    pub fn block(self: *Cac) periph.Block {
        return .{
            .name = "CAC",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

/// The part of a 16-bit register a narrow access names.
fn part(value: u16, byte_offset: u32, width: u3) u32 {
    const shift: u4 = @intCast(byte_offset * 8);
    const shifted = @as(u32, value) >> shift;
    return if (width == 1) shifted & 0xFF else shifted;
}

/// Fold a narrow write into a 16-bit register without disturbing the byte the
/// access does not name.
fn merge(current: u16, byte_offset: u32, width: u3, value: u32) u16 {
    if (width >= 2 and byte_offset == 0) return @truncate(value);
    const shift: u4 = @intCast(byte_offset * 8);
    const window: u16 = @as(u16, 0xFF) << shift;
    const placed: u16 = @truncate((value & 0xFF) << shift);
    return (current & ~window) | placed;
}

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Cac = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Cac = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}

/// The address of one CAC register, so a test or a later slice does not have to
/// do the arithmetic itself.
pub fn regAddress(offset: u32) u32 {
    return win_base + offset;
}
