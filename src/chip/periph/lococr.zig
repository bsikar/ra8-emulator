//! LOCOCR: the low-speed on-chip oscillator's stop bit (RA8EMU-311).
//!
//!   LOCOCR (0x4001_E400, 8b)  LCSTP b0  0 runs the LOCO, 1 stops it
//!
//! The offset is ra8_lpm_regs.h's k_ra8_lpm_lococr_off (0x400 on the SYSC
//! page, HUM Ch 9.2.15). ra8_lpm_set_clock_stop read-modify-writes bit 0
//! inside RA8_PROTECTED_WRITE(k_ra8_prcr_unlock_cgc), and the RTC driver
//! clears LCSTP the same way before it selects the LOCO, so lpm_periodic_idle
//! and lpm_ulpt_standby both stored here into nothing.
//!
//! RESET STATE: LCSTP clear, the LOCO running. The RTC driver's own comment
//! says the LOCO "is normally already running" when it clears the bit.
//!
//! PRCR.PRC0 GATES EVERY STORE, as it does for the other oscillator control
//! registers in oscsf.zig and subclock.zig: a store with PRC0 locked is
//! dropped and counted. Reads are never gated. Nothing here stabilises: no
//! OSCSF bit follows the LOCO in this model.
const periph = @import("registry.zig");
const lanes = @import("lanes.zig");
const prcr = @import("prcr.zig");

pub const address: u32 = 0x4001_E400;
pub const lcstp: u8 = 1 << 0;
pub const guard: u16 = prcr.group.cgc;

pub const Unit = struct {
    /// The board's live protection model, not a copy of it.
    protection: *const prcr.Prcr,
    lococr: u8 = 0,
    /// Stores that landed.
    stores: u32 = 0,
    /// Stores dropped because PRCR.PRC0 was locked.
    dropped_locked: u32 = 0,
    /// Times firmware set LCSTP on a running LOCO.
    stops: u32 = 0,
    /// Times firmware cleared LCSTP on a stopped LOCO.
    starts: u32 = 0,

    pub fn init(protection: *const prcr.Prcr) Unit {
        return .{ .protection = protection };
    }

    pub fn quiet(self: *const Unit) bool {
        return self.stores == 0 and self.dropped_locked == 0;
    }

    pub fn running(self: *const Unit) bool {
        return self.lococr & lcstp == 0;
    }

    pub fn read(self: *const Unit, at: u32, width: u3) u32 {
        return lanes.part(self.lococr, at - address, width);
    }

    pub fn write(self: *Unit, at: u32, width: u3, value: u32) void {
        _ = width;
        if (at != address) return;
        if (!self.protection.unlocked(guard)) {
            self.dropped_locked +%= 1;
            return;
        }
        const was_running = self.running();
        self.lococr = @truncate(value);
        self.stores +%= 1;
        if (was_running and !self.running()) self.stops +%= 1;
        if (!was_running and self.running()) self.starts +%= 1;
    }

    pub fn block(self: *Unit) periph.Block {
        return .{
            .name = "LOCO",
            .base = address,
            .size = 1,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, at: u32, width: u3) u32 {
    const self: *Unit = @ptrCast(@alignCast(context));
    return self.read(at, width);
}

fn writeThunk(context: *anyopaque, at: u32, width: u3, value: u32) void {
    const self: *Unit = @ptrCast(@alignCast(context));
    self.write(at, width, value);
}
