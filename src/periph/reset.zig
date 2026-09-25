//! RSTSR: why the part booted, so a firmware can read its own reset cause.
//!
//! The RA8D2 latches the cause of every reset in the RSTSRn registers inside
//! R_SYSTEM and keeps them across the reset itself: that is the whole point of
//! them, a firmware asks "why am I running" on the way up and takes a different
//! path after a watchdog reset than after a power-on. Ported from
//! board_periph_reset.c on dev.
//!
//! The registers sit in two separate stretches of SYSC rather than one window,
//! so this block claims both and leaves the rest of R_SYSTEM to the sparse
//! file and to the other SYSC models (PRCR, the backup file, the voltage
//! monitors):
//!
//!   RSTSR1 (32b) 0x4001_E0C0   IWDTRF, WDTRF, SWRF
//!   RSTSR0  (8b) 0x4001_EA40   PORF, plus RSTSR2 (CWSF) +0x04, RSTSR3 +0x08
//!
//! Without a model the sparse file answers these, and a sparse read of an
//! address nothing wrote alternates zero and all-ones, so a driver asking for
//! the cause gets either "no flags at all" or "every cause at once", and both
//! readings are wrong.
const periph = @import("registry.zig");

/// RSTSR1 geometry: one 32-bit register.
pub const rstsr1 = struct {
    pub const base: u32 = 0x4001_E0C0;
    pub const span: u32 = 0x4;
};

/// RSTSR0 geometry: the 8-bit RSTSR0 with RSTSR2 and RSTSR3 behind it.
pub const rstsr0 = struct {
    pub const base: u32 = 0x4001_EA40;
    pub const span: u32 = 0xC;
    pub const off_r0: u32 = 0x00;
    pub const off_r2: u32 = 0x04;
    pub const off_r3: u32 = 0x08;
};

/// The cause bits this model latches. RSTSR0 carries the power-on flag;
/// RSTSR1 carries the ones a running firmware can cause itself.
pub const cause = struct {
    /// RSTSR0.PORF, bit 0: a power-on reset.
    pub const porf: u8 = 0x01;
    /// RSTSR1.IWDTRF, bit 0: an independent-watchdog reset.
    pub const iwdtrf: u32 = 0x0000_0001;
    /// RSTSR1.WDTRF, bit 1: a watchdog-0 reset.
    pub const wdtrf: u32 = 0x0000_0002;
    /// RSTSR1.SWRF, bit 2: a software reset (AIRCR.SYSRESETREQ).
    pub const swrf: u32 = 0x0000_0004;
    pub const rstsr1_all: u32 = iwdtrf | wdtrf | swrf;
};

/// What asked for the reboot. The watchdog is the only source wired up so far;
/// a software reset arrives once the engine models AIRCR.SYSRESETREQ.
pub const Source = enum { watchdog, iwdt, software };

/// The latched cause flags plus the pending reboot request.
///
/// The flags are sticky on purpose: they survive the reboot they describe, and
/// clear only when the firmware clears them or the process starts again. A
/// fresh Reset is a cold boot, so PORF is set from the start.
pub const Reset = struct {
    rstsr1: u32 = 0,
    rstsr0: u8 = cause.porf,
    rstsr2: u8 = 0,
    rstsr3: u8 = 0,
    /// A reboot a peripheral has asked for and nothing has performed yet.
    pending: ?Source = null,
    /// Reboots requested over the whole run.
    requests: u32 = 0,
    /// Acks that cleared nothing because they wrote a one at a set flag.
    bad_acks: u32 = 0,

    pub fn init() Reset {
        return .{};
    }

    /// A run that never touched the block and never had a cause latched past
    /// the power-on one stays out of the end-of-run report.
    pub fn quiet(self: *const Reset) bool {
        return self.rstsr1 == 0 and self.pending == null and
            self.requests == 0 and self.bad_acks == 0;
    }

    /// Whether the firmware would see `flag` in RSTSR1 right now.
    pub fn latched(self: *const Reset, flag: u32) bool {
        return self.rstsr1 & flag != 0;
    }

    /// A peripheral asking for the part to be reset. Silicon reboots here; the
    /// cause is latched at once so it is readable either way, and the request
    /// is held for whoever performs the reboot.
    pub fn request(self: *Reset, source: Source) void {
        self.pending = source;
        self.requests +%= 1;
        self.setCause(source);
    }

    /// The reboot happened: PORF drops because this was not a power-on, and
    /// the cause flag stays latched for the firmware coming up.
    pub fn setCause(self: *Reset, source: Source) void {
        self.rstsr0 &= ~cause.porf;
        self.rstsr1 |= switch (source) {
            .watchdog => cause.wdtrf,
            .iwdt => cause.iwdtrf,
            .software => cause.swrf,
        };
    }

    /// Hand the pending request to the caller that will perform it, once.
    pub fn takeRequest(self: *Reset) ?Source {
        defer self.pending = null;
        return self.pending;
    }

    pub fn read(self: *Reset, address: u32, width: u3) u32 {
        _ = width;
        if (address >= rstsr1.base and address < rstsr1.base + rstsr1.span) {
            return self.rstsr1 >> @as(u5, @intCast((address - rstsr1.base) * 8));
        }
        return switch (address -% rstsr0.base) {
            rstsr0.off_r0 => self.rstsr0,
            rstsr0.off_r2 => self.rstsr2,
            rstsr0.off_r3 => self.rstsr3,
            else => 0,
        };
    }

    pub fn write(self: *Reset, address: u32, width: u3, value: u32) void {
        _ = width;
        if (address >= rstsr1.base and address < rstsr1.base + rstsr1.span) {
            self.rstsr1 = self.ack(u32, self.rstsr1, value);
            return;
        }
        switch (address -% rstsr0.base) {
            rstsr0.off_r0 => self.rstsr0 = self.ack(u8, self.rstsr0, value),
            // CWSF is not a cause flag: it is a plain bit the firmware sets to
            // tell its own next boot the cold-start path already ran.
            rstsr0.off_r2 => self.rstsr2 = @truncate(value),
            rstsr0.off_r3 => self.rstsr3 = @truncate(value),
            else => {},
        }
    }

    /// RSTSRn flags clear on a written zero: "read 1 then write 0". A written
    /// one keeps the bit standing, so a driver that acks the way it would ack
    /// a W1C flag elsewhere on this part clears nothing at all.
    fn ack(self: *Reset, comptime T: type, held: T, value: u32) T {
        const kept = held & @as(T, @truncate(value));
        if (kept != 0) self.bad_acks +%= 1;
        return kept;
    }

    /// The RSTSR1 window. Two blocks because the registers are not adjacent.
    pub fn statusBlock(self: *Reset) periph.Block {
        return .{
            .name = "SYSC-RSTSR1",
            .base = rstsr1.base,
            .size = rstsr1.span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }

    /// The RSTSR0 / RSTSR2 / RSTSR3 window.
    pub fn causeBlock(self: *Reset) periph.Block {
        return .{
            .name = "SYSC-RSTSR0",
            .base = rstsr0.base,
            .size = rstsr0.span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Reset = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Reset = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}

/// The cause flags in the words the end-of-run report uses, newest first.
pub fn name(source: Source) []const u8 {
    return switch (source) {
        .watchdog => "WDT",
        .iwdt => "IWDT",
        .software => "SW",
    };
}
