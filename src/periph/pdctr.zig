//! PDCTRn: a switchable power domain, and the register that gates it.
//!
//! The RA8D2 puts whole peripheral families behind a power switch and gates
//! each one with a single 8-bit register in the SYSC window. Two of them are
//! modelled here, because two of them decide whether a block this emulator
//! already carries answers at all:
//!
//!   PDCTRGD   (+0x110, 8b)  MIPI DSI, MIPI CSI, VIN, DRW and GLCDC
//!   PDCTRESWM (+0x118, 8b)  the Ethernet switch: ETHA and RMAC, both ports
//!
//! Both carry the same three fields, PDDE b0, PDCSF b6 and PDPGSF b7, and both
//! come out of reset at 0x81: PDPGSF set, meaning the domain is gated off, and
//! PDDE set, meaning "power off the target domain". So every block inside one
//! is unpowered out of reset, and cancelling a module-stop bit is not enough
//! to wake it. PDCTRGD is HUM Ch 11.2.14 p 452 and was ported from
//! board_periph_pdctr.c on dev; PDCTRESWM is HUM Ch 9.2 "General Power Domain
//! ESWM Control Register", cited by ra8_system_regs.h at +0x118.
//!
//! PDDE has inverted polarity: a write of 0 powers the domain ON. That is the
//! whole trap. Without a model the sparse register file answers the register,
//! so a firmware reads back whatever it wrote and believes the domain came up,
//! and a firmware that never wrote it at all reads 0 and believes the same
//! thing. On the bench the domain is dark either way: the C tree's issue #247
//! was a D/AVE 2D engine that had never rasterised a pixel because nothing
//! cleared PDDE, while the emulator, modelling no power domain at all, let the
//! firmware drive it happily. ra8_cgc_eswclk.c records the same failure for
//! the other domain in so many words: "every per-port RMAC / ETHA register
//! read returns 0 and writes are silently dropped until PDCTRESWM.PDDE = 0",
//! marked as observed on EK-RA8D2 hardware.
//!
//! Both registers are PRC1-protected (HUM Ch 13.1 Table 13.1 p 521), so a
//! write made with that group locked is discarded with no fault and no status
//! flag, exactly the silence PRCR gives everywhere else on this part.
//!
//! NOT MODELLED, AND NOT GUESSED: the settling time. PDCSF reports a transition
//! in progress and no page in reach gives its duration, so gating is
//! instantaneous here and PDCSF always settles to 0. A driver polling it makes
//! progress; one timing it would not learn anything true.
const periph = @import("registry.zig");
const prcr = @import("prcr.zig");

/// Every domain register is one byte wide.
pub const win_span: u32 = 0x1;

/// Which power domain a model instance gates. A real enumeration: the part
/// has these domains and no others in reach of this tree, and each one knows
/// where it answers and what to call it.
pub const Domain = enum {
    graphics,
    eswm,

    /// Where the register sits in the SYSC window.
    pub fn base(self: Domain) u32 {
        return switch (self) {
            .graphics => 0x4001_E110,
            .eswm => 0x4001_E118,
        };
    }

    /// What the bus and the end-of-run report call this domain.
    pub fn label(self: Domain) []const u8 {
        return switch (self) {
            .graphics => "PWR-GRAPHICS",
            .eswm => "PWR-ESWM",
        };
    }

    /// The register a driver has to clear PDDE in, named so the report can
    /// tell a firmware author which one they missed.
    pub fn register(self: Domain) []const u8 {
        return switch (self) {
            .graphics => "PDCTRGD",
            .eswm => "PDCTRESWM",
        };
    }
};

/// The field masks, shared by both registers (HUM Ch 11.2.14 p 452 for
/// PDCTRGD, Ch 9.2 for PDCTRESWM).
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

/// The group both registers sit behind: PRC1, low-power modes.
pub const guard: u16 = prcr.group.lpm;

/// The gating state, plus the counters behind the end-of-run line.
pub const Pdctr = struct {
    /// The protection model this block asks before accepting a store. It is a
    /// pointer, not a copy, so the answer is the board's live PRCR.
    protection: *const prcr.Prcr,
    /// Which domain this instance gates, and so where it answers.
    which: Domain,
    held: u8 = field.reset_value,
    /// Times the domain went from gated to powered.
    power_ons: u32 = 0,
    /// Writes dropped because PRCR.PRC1 was locked.
    dropped_locked: u32 = 0,
    /// Writes that asked for the domain to be powered off again.
    power_offs: u32 = 0,

    pub fn init(protection: *const prcr.Prcr, which: Domain) Pdctr {
        return .{ .protection = protection, .which = which };
    }

    /// A run that never wrote the register leaves the domain gated exactly as
    /// reset left it, and there is nothing to narrate.
    pub fn quiet(self: *const Pdctr) bool {
        return self.power_ons == 0 and self.dropped_locked == 0 and self.power_offs == 0;
    }

    /// Whether the domain is powered right now. This is the question a block
    /// inside it asks before answering with a live value.
    pub fn powered(self: *const Pdctr) bool {
        return self.held & field.pdpgsf == 0;
    }

    pub fn read(self: *Pdctr, address: u32, width: u3) u32 {
        _ = address;
        _ = width;
        return self.held;
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
            self.held = field.pdde | field.pdpgsf;
            return;
        }
        if (!self.powered()) self.power_ons +%= 1;
        self.held = 0;
    }

    pub fn block(self: *Pdctr) periph.Block {
        return .{
            .name = self.which.label(),
            .base = self.which.base(),
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

/// The two domains a board carries, so a board holds one field rather than
/// one per domain. Both are built together because both ask the same PRCR.
pub const Domains = struct {
    graphics: Pdctr,
    eswm: Pdctr,

    pub fn init(protection: *const prcr.Prcr) Domains {
        return .{
            .graphics = Pdctr.init(protection, .graphics),
            .eswm = Pdctr.init(protection, .eswm),
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
