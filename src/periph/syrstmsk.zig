//! SYRSTMSK0/1/2: which reset sources the part is still allowed to act on.
//!
//! Twelve reset sources each have a mask bit across three bytes in SYSC (HUM
//! Ch 6.2.6-6.2.8 p 262-263). A set bit DISABLES that reset, so a firmware
//! that masks the bus-error reset keeps running through a bus fault that
//! would otherwise reboot it. The group sits behind PRCR.PRC5, the same
//! protect register the clock tree and the voltage monitors sit behind.
//!
//! TWO OF THE BITS CANNOT BE REWRITTEN WHILE THEIR WATCHDOG RUNS. HUM Ch
//! 6.2.6 p 263 says IWDTMASK cannot be rewritten while the independent
//! watchdog is running, and WDT0MASK cannot be rewritten while the CPU0
//! watchdog is running; the hardware SILENTLY IGNORES such a write.
//! ra8_reset.h carries the same warning over ra8_reset_set_source_mask and
//! tells the caller to mask those sources before starting their watchdogs.
//!
//! A model that takes those writes anyway is wrong in the direction that
//! hides the bug: the firmware reads its mask back, sees what it asked for,
//! and believes it has disarmed a watchdog reset it has not disarmed. So the
//! write is dropped, the OTHER bits in the same store still land (silicon
//! ignores the one bit, not the byte), and the run says how many times it
//! happened. Neither refused nor flagged, since silicon does neither: the
//! cut the DOTF reversed-pair and OCTACLK early-release slices took.
const periph = @import("registry.zig");
const prcr = @import("prcr.zig");

/// The three mask bytes, on a 4-byte pitch inside SYSC.
pub const win_base: u32 = 0x4001_EAD0;
pub const win_span: u32 = 0xC;

pub const off = struct {
    pub const msk0: u32 = 0x0;
    pub const msk1: u32 = 0x4;
    pub const msk2: u32 = 0x8;
};

/// SYRSTMSK0. A set bit disables that reset.
pub const msk0 = struct {
    pub const iwdt: u8 = 0x01;
    pub const wdt0: u8 = 0x02;
    pub const sw: u8 = 0x04;
    pub const clu0: u8 = 0x10;
    pub const lm0: u8 = 0x20;
    pub const cm: u8 = 0x40;
    pub const bus: u8 = 0x80;
};

/// SYRSTMSK1, the CPU1 side.
pub const msk1 = struct {
    pub const wdt1: u8 = 0x02;
    pub const clu1: u8 = 0x10;
    pub const lm1: u8 = 0x20;
};

/// SYRSTMSK2, the two voltage monitors.
pub const msk2 = struct {
    pub const pvd1: u8 = 0x01;
    pub const pvd2: u8 = 0x02;
};

/// PRCR.PRC5 guards the whole reset-control group.
pub const guard: u16 = prcr.group.rst;

/// The three mask bytes and what the firmware got wrong reaching them.
pub const Mask = struct {
    /// The board's own protection model, not a copy of it.
    protection: *const prcr.Prcr,
    /// The two watchdogs' own armed flags, so the write-while-running rule
    /// reads live state rather than a copy that can go stale.
    watchdog_armed: *const bool,
    heartbeat_armed: *const bool,

    m0: u8 = 0,
    m1: u8 = 0,
    m2: u8 = 0,

    /// Stores discarded whole because PRC5 was shut.
    dropped_locked: u32 = 0,
    /// IWDTMASK bits a store tried to change while the IWDT was running.
    ignored_iwdt: u32 = 0,
    /// WDT0MASK bits a store tried to change while the CPU0 WDT was running.
    ignored_wdt0: u32 = 0,

    pub fn init(
        protection: *const prcr.Prcr,
        watchdog_armed: *const bool,
        heartbeat_armed: *const bool,
    ) Mask {
        return .{
            .protection = protection,
            .watchdog_armed = watchdog_armed,
            .heartbeat_armed = heartbeat_armed,
        };
    }

    /// A run that never masked anything and never got a store wrong stays
    /// out of the end-of-run report.
    pub fn quiet(self: *const Mask) bool {
        return self.m0 == 0 and self.m1 == 0 and self.m2 == 0 and
            self.dropped_locked == 0 and self.ignored_iwdt == 0 and
            self.ignored_wdt0 == 0;
    }

    /// Whether the reset named by `bit` in SYRSTMSK0 is currently disabled.
    pub fn disabled0(self: *const Mask, bit: u8) bool {
        return self.m0 & bit != 0;
    }

    pub fn read(self: *Mask, address: u32, width: u3) u32 {
        _ = width;
        return switch (address -% win_base) {
            off.msk0 => self.m0,
            off.msk1 => self.m1,
            off.msk2 => self.m2,
            else => 0,
        };
    }

    pub fn write(self: *Mask, address: u32, width: u3, value: u32) void {
        _ = width;
        // PRC5 shut means the store is discarded with no fault and no status
        // bit. Counting it is the only way the run can say so.
        if (!self.protection.unlocked(guard)) {
            self.dropped_locked +%= 1;
            return;
        }
        const byte: u8 = @truncate(value);
        switch (address -% win_base) {
            off.msk0 => self.m0 = self.frozen(byte),
            off.msk1 => self.m1 = byte,
            off.msk2 => self.m2 = byte,
            else => {},
        }
    }

    /// SYRSTMSK0 with the two watchdog bits held at what they already are
    /// whenever their watchdog is running. The rest of the byte still lands.
    fn frozen(self: *Mask, byte: u8) u8 {
        var out = byte;
        if (self.heartbeat_armed.* and (byte & msk0.iwdt) != (self.m0 & msk0.iwdt)) {
            self.ignored_iwdt +%= 1;
            out = (out & ~msk0.iwdt) | (self.m0 & msk0.iwdt);
        }
        if (self.watchdog_armed.* and (byte & msk0.wdt0) != (self.m0 & msk0.wdt0)) {
            self.ignored_wdt0 +%= 1;
            out = (out & ~msk0.wdt0) | (self.m0 & msk0.wdt0);
        }
        return out;
    }

    pub fn block(self: *Mask) periph.Block {
        return .{
            .name = "SYSC-SYRSTMSK",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Mask = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Mask = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
