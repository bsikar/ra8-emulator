//! PDCTRGD: the graphics power domain, which is switched OFF at reset.
//!
//! The RA8D2 puts MIPI DSI, MIPI CSI, VIN, DRW and GLCDC inside one switchable
//! power domain (HUM Ch 11.5.1 Table 11.7 p 480) and gates it with a single
//! 8-bit register, PDCTRGD at SYSC + 0x110 (HUM Ch 11.2.14 p 452). Its reset
//! value is 0x81: PDPGSF set, meaning the domain is gated off, and PDDE set,
//! meaning "power off the target domain". So every graphics peripheral is
//! unpowered out of reset, and cancelling a module-stop bit is not enough to
//! wake one. Ported from board_periph_pdctr.c on dev.
//!
//! PDDE has inverted polarity: a write of 0 powers the domain ON. That is the
//! whole trap. Without a model the sparse register file answers PDCTRGD, so a
//! firmware reads back whatever it wrote and believes the domain came up, and
//! a firmware that never wrote it at all reads 0 and believes the same thing.
//! On the bench the domain is dark either way: the C tree's issue #247 was a
//! D/AVE 2D engine that had never rasterised a pixel because nothing cleared
//! PDDE, while the emulator, modelling no power domain at all, let the
//! firmware drive it happily.
//!
//!   PDCTRGD (+0x110, 8b)  PDDE b0, PDCSF b6, PDPGSF b7
//!
//! The register is PRC1-protected (HUM Ch 13.1 Table 13.1 p 521), so a write
//! made with that group locked is discarded with no fault and no status flag,
//! exactly the silence PRCR gives everywhere else on this part.
const periph = @import("registry.zig");
const prcr = @import("prcr.zig");

/// PDCTRGD geometry: SYSC base 0x4001_E000 + 0x110, one 8-bit register.
pub const win_base: u32 = 0x4001_E110;
pub const win_span: u32 = 0x1;

/// PDCTRGD field masks (HUM Ch 11.2.14 p 452).
pub const field = struct {
    /// PDDE, bit 0: 1 = power the target domain OFF. Inverted polarity.
    pub const pdde: u8 = 0x01;
    /// PDCSF, bit 6: a power-control transition is in progress.
    pub const pdcsf: u8 = 0x40;
    /// PDPGSF, bit 7: 1 = the domain is gated off right now.
    pub const pdpgsf: u8 = 0x80;
    /// "Value after reset": gated off, and asked to stay off.
    pub const reset_value: u8 = pdde | pdpgsf;
};

/// The group PDCTRGD sits behind: PRC1, low-power modes.
pub const guard: u16 = prcr.group.lpm;

/// The gating state, plus the counters behind the end-of-run line.
pub const Pdctr = struct {
    /// The protection model this block asks before accepting a store. It is a
    /// pointer, not a copy, so the answer is the board's live PRCR.
    protection: *const prcr.Prcr,
    pdctrgd: u8 = field.reset_value,
    /// Times the domain went from gated to powered.
    power_ons: u32 = 0,
    /// Writes dropped because PRCR.PRC1 was locked.
    dropped_locked: u32 = 0,
    /// Writes that asked for the domain to be powered off again.
    power_offs: u32 = 0,

    pub fn init(protection: *const prcr.Prcr) Pdctr {
        return .{ .protection = protection };
    }

    /// A run that never wrote the register leaves the domain gated exactly as
    /// reset left it, and there is nothing to narrate.
    pub fn quiet(self: *const Pdctr) bool {
        return self.power_ons == 0 and self.dropped_locked == 0 and self.power_offs == 0;
    }

    /// Whether the graphics domain is powered right now. This is the question
    /// a block inside the domain asks before answering with a live value.
    pub fn powered(self: *const Pdctr) bool {
        return self.pdctrgd & field.pdpgsf == 0;
    }

    pub fn read(self: *Pdctr, address: u32, width: u3) u32 {
        _ = address;
        _ = width;
        return self.pdctrgd;
    }

    /// PDDE selects the target state, PDCSF reports a transition in progress
    /// and PDPGSF reports the resulting gate state. Gating is instantaneous
    /// here, so PDCSF always settles to 0 and PDPGSF simply follows PDDE: a
    /// driver polling "PDCSF == 0" makes progress, and one polling "domain
    /// still gated" gets a real answer.
    pub fn write(self: *Pdctr, address: u32, width: u3, value: u32) void {
        _ = address;
        _ = width;
        if (!self.protection.unlocked(guard)) {
            self.dropped_locked +%= 1;
            return;
        }
        const wants_off = @as(u8, @truncate(value)) & field.pdde != 0;
        if (wants_off) {
            if (self.powered()) self.power_offs +%= 1;
            self.pdctrgd = field.pdde | field.pdpgsf;
            return;
        }
        if (!self.powered()) self.power_ons +%= 1;
        self.pdctrgd = 0;
    }

    pub fn block(self: *Pdctr) periph.Block {
        return .{
            .name = "PWR-GRAPHICS",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Pdctr = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Pdctr = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
