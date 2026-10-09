//! VSCR: the core voltage scaling register, where the transition flag is the
//! hardware's to set and never the firmware's.
//!
//! The last address in the EIL corpus nothing modelled: 26 of the 36 images
//! write 0x4001_E014 with 1 and then read it back, and every one of those
//! accesses fell through to the anonymous shadow. It is step 2 of
//! ra8_cgc.c's bring-up, and its own file header says why the step exists:
//! "Drop the core voltage to not high voltage range (R_SYSTEM->VSCR.VSCM = 1)
//! and wait for VSCMTSF to clear. Required before lifting PLL above its boot
//! rate", because without it "the PLL writes succeed but the chip browns out
//! as soon as CPUCLK0 lifts past the high-voltage threshold".
//!
//!   VSCR (0x4001_E014, 32b)  VSCM bit 0, VSCMTSF bit 4 (read-only)
//!
//! Offset and bits are from libs/ra8_hal/inc/ra8_system_regs.h on zig/dev,
//! which cites HUM Ch 11.2.43 p 477 alongside FSP bsp_clocks.c.
//!
//! TWO THINGS A SHADOW CELL GETS WRONG.
//!
//! VSCMTSF is read-only: silicon raises it while the voltage transition is in
//! flight and lowers it when the transition lands, and a store never touches
//! it. A shadow cell takes whatever is written, so firmware that writes the
//! whole register with bit 4 set reads that bit back forever, and
//! ra8_hw_wait_flag_clear32 spins out its whole budget waiting for a flag
//! nothing will ever clear. The emulator would report a timeout the bench
//! does not have. Here the bit is never stored, and a store that named it is
//! counted so the report can say the firmware tried.
//!
//! And the transition itself has no duration in this model, so VSCMTSF reads
//! zero: by the time the driver looks, the voltage has already moved. That is
//! the honest answer for an emulator with no wall clock, and it is what makes
//! the driver's wait loop finish on its first read rather than on the shadow
//! cell's alternating poll answer.
//!
//! DELIBERATELY NOT MODELLED. Whether VSCM can be cleared again to climb back
//! into the high-voltage range: the tree only ever writes 1 and documents the
//! bit as "write 1 to enter not-high-voltage mode", so the bit is latched both
//! ways here and nothing in this file claims the return path is real. No
//! voltage, no timing and no brown-out: the run records which range was
//! selected, not what the core would have survived.
const periph = @import("registry.zig");
const prcr = @import("prcr.zig");
const lanes = @import("lanes.zig");

/// The group this sits behind. ra8_cgc.c reaches VSCR only from
/// internal_cgc_init_protected, and internal_set_vscr_not_high_v states the
/// precondition outright: the caller has unlocked PRCR group 0.
pub const guard: u16 = prcr.group.cgc;

pub const win_base: u32 = 0x4001_E014;
pub const win_span: u32 = 4;

pub const bit = struct {
    /// VSCM: 1 selects the not-high-voltage range.
    pub const vscm: u32 = 1 << 0;
    /// VSCMTSF: set by hardware while the transition is in flight.
    pub const vscmtsf: u32 = 1 << 4;
};

/// Which core voltage range VSCM selects.
pub const Range = enum {
    high_voltage,
    not_high_voltage,

    pub fn name(self: Range) []const u8 {
        return switch (self) {
            .high_voltage => "high voltage",
            .not_high_voltage => "not high voltage",
        };
    }
};

pub const Unit = struct {
    protection: *const prcr.Prcr,
    vscm: bool = false,
    /// Stores that landed.
    stores: u32 = 0,
    /// Stores dropped because PRCR.PRC0 was locked.
    dropped_locked: u32 = 0,
    /// Stores that named VSCMTSF, which hardware alone owns.
    flag_writes: u32 = 0,
    /// Range changes, so a run that scaled back and forth is visible.
    transitions: u32 = 0,

    pub fn init(protection: *const prcr.Prcr) Unit {
        return .{ .protection = protection };
    }

    pub fn quiet(self: *const Unit) bool {
        return self.stores == 0 and self.dropped_locked == 0 and self.flag_writes == 0;
    }

    pub fn range(self: *const Unit) Range {
        return if (self.vscm) .not_high_voltage else .high_voltage;
    }

    /// The word a load is served from: VSCM as written, VSCMTSF clear because
    /// the transition has already landed.
    fn word(self: *const Unit) u32 {
        return if (self.vscm) bit.vscm else 0;
    }

    pub fn read(self: *Unit, address: u32, width: u3) u32 {
        return lanes.part(self.word(), address - win_base, width);
    }

    pub fn write(self: *Unit, address: u32, width: u3, value: u32) void {
        if (!self.protection.unlocked(guard)) {
            self.dropped_locked +%= 1;
            return;
        }
        const merged = lanes.merge(self.word(), address - win_base, width, value);
        if (merged & bit.vscmtsf != 0) self.flag_writes +%= 1;
        const wanted = merged & bit.vscm != 0;
        if (wanted != self.vscm) self.transitions +%= 1;
        self.vscm = wanted;
        self.stores +%= 1;
    }

    pub fn block(self: *Unit) periph.Block {
        return .{
            .name = "VSCR",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Unit = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Unit = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
