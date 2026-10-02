//! The special registers MRS and MSR name with an 8-bit SYSm, read and written
//! the way the Armv8-M pseudocode does it for one Security state.
//!
//! Unprivileged code reads zero from the stack pointers and masks and its
//! writes to them are ignored; CONTROL reads back whatever the privilege. EPSR
//! always reads as zero. MSPLIM and PSPLIM hold bits 31:3. The Non-secure
//! aliases (SYSm 0x88 and up) are not modelled here yet, so `known` leaves
//! them out.
const regs = @import("regs.zig");
const Regs = regs.Regs;

pub const sysm = struct {
    pub const xpsr_last: u8 = 7;
    pub const reserved_psr: u8 = 4;
    pub const msp: u8 = 8;
    pub const psp: u8 = 9;
    pub const msplim: u8 = 10;
    pub const psplim: u8 = 11;
    pub const primask: u8 = 16;
    pub const basepri: u8 = 17;
    pub const basepri_max: u8 = 18;
    pub const faultmask: u8 = 19;
    pub const control: u8 = 20;
};

pub const psr_bits = struct {
    /// N, Z, C, V and Q.
    pub const nzcvq: u32 = 0xF800_0000;
    /// GE[3:0], from the DSP extension both RA8 cores carry.
    pub const ge: u32 = 0x000F_0000;
};

/// The bits MSPLIM and PSPLIM keep: the limit is 8-byte aligned.
pub const limit_bits: u32 = 0xFFFF_FFF8;

/// CONTROL bits MSR may change: nPRIV, SPSEL and FPCA.
pub const control_writable: u32 = 0x7;

/// Whether SYSm names a register this file models.
pub fn known(n: u8) bool {
    return switch (n) {
        0...sysm.xpsr_last => n != sysm.reserved_psr,
        sysm.msp...sysm.psplim => true,
        sysm.primask...sysm.control => true,
        else => false,
    };
}

pub fn privileged(r: *const Regs) bool {
    return r.handlerMode() or r.control & regs.control_bits.npriv == 0;
}

/// The value MRS returns. `n` must be `known`.
pub fn read(r: *const Regs, n: u8) u32 {
    if (n <= sysm.xpsr_last) return readPsr(r.xpsr, n);
    if (n == sysm.control) return r.control;
    if (!privileged(r)) return 0;
    return switch (n) {
        sysm.msp => r.msp,
        sysm.psp => r.psp,
        sysm.msplim => r.msplim,
        sysm.psplim => r.psplim,
        sysm.primask => r.primask,
        sysm.basepri, sysm.basepri_max => r.basepri,
        sysm.faultmask => r.faultmask,
        else => unreachable,
    };
}

/// SYSm[0] adds IPSR, SYSm[2] clear adds the APSR flags; EPSR reads zero.
fn readPsr(xpsr: u32, n: u8) u32 {
    var value: u32 = 0;
    if (n & 1 != 0) value |= xpsr & regs.xpsr_bits.ipsr;
    if (n & 4 == 0) value |= xpsr & (psr_bits.nzcvq | psr_bits.ge);
    return value;
}

/// MSR. `mask` is the two-bit field from the encoding (bit 1 the flags, bit 0
/// GE); it only matters for the xPSR forms. `n` must be `known`.
pub fn write(r: *Regs, n: u8, mask: u2, value: u32) void {
    if (n <= sysm.xpsr_last) return writePsr(r, n, mask, value);
    if (!privileged(r)) return;
    switch (n) {
        sysm.msp => r.write(.msp, value),
        sysm.psp => r.write(.psp, value),
        sysm.msplim => r.msplim = value & limit_bits,
        sysm.psplim => r.psplim = value & limit_bits,
        sysm.primask => r.write(.primask, value),
        sysm.basepri => r.write(.basepri, value),
        sysm.basepri_max => writeBasepriMax(r, value),
        sysm.faultmask => writeFaultmask(r, value),
        sysm.control => writeControl(r, value),
        else => unreachable,
    }
}

/// Only the APSR forms (SYSm[2] clear) write anything; IPSR and EPSR ignore it.
fn writePsr(r: *Regs, n: u8, mask: u2, value: u32) void {
    if (n & 4 != 0) return;
    var keep: u32 = 0;
    if (mask & 2 != 0) keep |= psr_bits.nzcvq;
    if (mask & 1 != 0) keep |= psr_bits.ge;
    r.xpsr = (r.xpsr & ~keep) | (value & keep);
}

/// BASEPRI_MAX only ever raises the priority it masks at: a zero write is
/// ignored, as is one that would lower a non-zero BASEPRI.
fn writeBasepriMax(r: *Regs, value: u32) void {
    const v = value & 0xFF;
    if (v != 0 and (r.basepri == 0 or v < r.basepri)) r.write(.basepri, v);
}

/// Setting FAULTMASK needs an execution priority above -1, so NMI and
/// HardFault (IPSR 2 and 3) can only clear it.
fn writeFaultmask(r: *Regs, value: u32) void {
    const ipsr = r.xpsr & regs.xpsr_bits.ipsr;
    if (value & 1 != 0 and (ipsr == 2 or ipsr == 3)) return;
    r.write(.faultmask, value);
}

/// SPSEL is only written from Thread mode; Handler mode keeps the old one.
fn writeControl(r: *Regs, value: u32) void {
    var writable = control_writable;
    if (r.handlerMode()) writable &= ~regs.control_bits.spsel;
    r.control = (r.control & ~writable) | (value & writable);
}
