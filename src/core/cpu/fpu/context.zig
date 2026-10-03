//! The FP context control registers (RA8EMU-170): FPCCR, FPCAR and FPDSCR
//! as the Arm ARM (DDI0553, "FPCCR", "FPCAR", "FPDSCR") lays them out for
//! Armv8.1-M with MVE, and the half of ExecuteFPCheck() that opens a new FP
//! context: when FPCCR.ASPEN is set and CONTROL.FPCA is clear, the first FP
//! instruction loads FPSCR from FPDSCR and sets CONTROL.FPCA.
//!
//! Secure/Non-secure banking of these registers and the Secure-only bits
//! (LSPENS, CLRONRETS, TS) belong to RA8EMU-165; lazy state preservation
//! (LSPACT, FPCAR use) to RA8EMU-163. Here every defined bit reads back as
//! written.
const Fpscr = @import("fpscr.zig").Fpscr;
const control_bits = @import("../regs.zig").control_bits;
const banked = @import("../../banked.zig");
const Vpr = @import("../mve/predicate.zig").Vpr;

/// FPCCR, least significant bit first.
pub const Fpccr = packed struct(u32) {
    lspact: u1 = 0,
    user: u1 = 0,
    s: u1 = 0,
    thread: u1 = 0,
    hfrdy: u1 = 0,
    mmrdy: u1 = 0,
    bfrdy: u1 = 0,
    sfrdy: u1 = 0,
    monrdy: u1 = 0,
    splimviol: u1 = 0,
    ufrdy: u1 = 0,
    _res11: u15 = 0,
    ts: u1 = 0,
    clronrets: u1 = 0,
    clronret: u1 = 0,
    lspens: u1 = 0,
    /// Lazy state preservation enabled; set out of reset.
    lspen: u1 = 1,
    /// CONTROL.FPCA set automatically on FP use; set out of reset.
    aspen: u1 = 1,

    /// The bits a write may change: every defined field.
    pub const writable: u32 = 0xFC00_07FF;
};

pub const masks = struct {
    /// FPCAR holds a doubleword-aligned frame address in bits 31:3.
    pub const fpcar: u32 = 0xFFFF_FFF8;
    /// FPDSCR's writable fields: AHP, DN, FZ, RMode and FZ16.
    pub const fpdscr: u32 = 0x07C8_0000;
    /// FPDSCR.LTPSIZE reads as 0b100 and ignores writes.
    pub const fpdscr_ltpsize: u32 = 0b100 << 16;
};

pub const Context = struct {
    fpccr: Fpccr = .{},
    fpcar: u32 = 0,
    fpdscr: u32 = masks.fpdscr_ltpsize,

    pub fn readFpccr(self: Context) u32 {
        return @bitCast(self.fpccr);
    }

    pub fn writeFpccr(self: *Context, value: u32) void {
        self.fpccr = @bitCast(value & Fpccr.writable);
    }

    pub fn writeFpcar(self: *Context, value: u32) void {
        self.fpcar = value & masks.fpcar;
    }

    pub fn writeFpdscr(self: *Context, value: u32) void {
        self.fpdscr = value & masks.fpdscr | masks.fpdscr_ltpsize;
    }

    /// The FPSCR a new FP context starts with: FPDSCR's defaults, every
    /// flag and NZCV clear, LTPSIZE 4.
    pub fn defaultFpscr(self: Context) Fpscr {
        return @bitCast(self.fpdscr);
    }

    /// ExecuteFPCheck() opening a new context: returns CONTROL as it
    /// stands after an FP instruction, loading `fpscr` from FPDSCR when
    /// this instruction is the one that sets FPCA.
    pub fn touch(
        self: *Context,
        control: u32,
        security: banked.State,
        fpscr: *Fpscr,
        vpr: *Vpr,
    ) u32 {
        self.fpccr.s = @intFromBool(security == .secure);
        const secure = security == .secure;
        const fresh = self.fpccr.aspen == 1 and
            (control & control_bits.fpca == 0 or
                (secure and control & control_bits.sfpa == 0));
        if (!fresh) return control;
        fpscr.* = self.defaultFpscr();
        vpr.* = .{};
        return control | control_bits.fpca | if (secure) control_bits.sfpa else 0;
    }
};
