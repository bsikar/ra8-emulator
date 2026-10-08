//! The Secure and Non-secure banks of the special registers, on top of the
//! Zig core's one-state register file (src/core/cpu/regs.zig leaves the
//! banks to this lane).
//!
//! Armv8-M banks MSP, PSP, MSPLIM, PSPLIM, PRIMASK, BASEPRI, FAULTMASK and
//! CONTROL.nPRIV/SPSEL and PACBTI enables by Security state. R0-R12, LR, PC and xPSR are
//! shared, and so are CONTROL.FPCA/SFPA. `Regs`
//! always holds the running state's copy; this keeps the other state's copy
//! and both stack limits, and swaps the two on a change of state.
//!
//! Secure code reaches the Non-secure copy through MRS/MSR with the _NS
//! SYSm encodings, checked against arm-none-eabi-as 13.3 for cortex-m33:
//! MSP_NS 0x88, PSP_NS 0x89, MSPLIM_NS 0x8A, PSPLIM_NS 0x8B, PRIMASK_NS
//! 0x90, BASEPRI_NS 0x91, FAULTMASK_NS 0x93, CONTROL_NS 0x94, SP_NS 0x98.
//! Those encodings from Non-secure state, and any other SYSm, return null
//! here and stay the executor's call.
const regs = @import("cpu/regs.zig");

pub const State = enum(u1) { secure, non_secure };

/// The CONTROL bits each state has its own copy of.
pub const control_banked: u32 = regs.control_bits.npriv | regs.control_bits.spsel |
    regs.control_bits.pac_en | regs.control_bits.bti_en |
    regs.control_bits.upac_en | regs.control_bits.ubti_en;

/// One state's banked registers.
pub const Bank = struct {
    msp: u32 = 0,
    psp: u32 = 0,
    msplim: u32 = 0,
    psplim: u32 = 0,
    primask: u32 = 0,
    basepri: u32 = 0,
    faultmask: u32 = 0,
    control: u32 = 0,
    low_msp: u32 = regs.never_low,
    low_psp: u32 = regs.never_low,

    fn setMsp(self: *Bank, value: u32) void {
        self.msp = value;
        self.low_msp = @min(self.low_msp, value);
    }

    fn setPsp(self: *Bank, value: u32) void {
        self.psp = value;
        self.low_psp = @min(self.low_psp, value);
    }
};

pub const sysm = struct {
    pub const msp_ns: u8 = 0x88;
    pub const psp_ns: u8 = 0x89;
    pub const msplim_ns: u8 = 0x8A;
    pub const psplim_ns: u8 = 0x8B;
    pub const primask_ns: u8 = 0x90;
    pub const basepri_ns: u8 = 0x91;
    pub const faultmask_ns: u8 = 0x93;
    pub const control_ns: u8 = 0x94;
    pub const sp_ns: u8 = 0x98;
};

pub const Banked = struct {
    /// The state `Regs` holds. A Security Extension core resets Secure.
    current: State = .secure,
    /// The other state's copy of everything banked.
    other: Bank = .{},

    fn capture(r: *const regs.Regs) Bank {
        return .{
            .msp = r.msp,
            .psp = r.psp,
            .msplim = r.msplim,
            .psplim = r.psplim,
            .primask = r.primask,
            .basepri = r.basepri,
            .faultmask = r.faultmask,
            .control = r.control & control_banked,
            .low_msp = r.low_msp,
            .low_psp = r.low_psp,
        };
    }

    fn restore(r: *regs.Regs, from: Bank) void {
        r.msp = from.msp;
        r.psp = from.psp;
        r.msplim = from.msplim;
        r.psplim = from.psplim;
        r.primask = from.primask;
        r.basepri = from.basepri;
        r.faultmask = from.faultmask;
        r.low_msp = from.low_msp;
        r.low_psp = from.low_psp;
        r.control = (r.control & ~control_banked) | (from.control & control_banked);
    }

    /// Make `state` the running one: park the running copy and bring the
    /// other in. The shared registers are left alone.
    pub fn switchTo(self: *Banked, r: *regs.Regs, state: State) void {
        if (state == self.current) return;
        const parked = capture(r);
        restore(r, self.other);
        self.other = parked;
        self.current = state;
    }

    /// One state's copy, wherever it lives right now.
    pub fn bank(self: *const Banked, r: *const regs.Regs, state: State) Bank {
        return if (state == self.current) capture(r) else self.other;
    }

    /// The Non-secure SP as Non-secure code would see it: Handler mode or
    /// a clear SPSEL picks MSP_NS.
    fn spNs(b: Bank, r: *const regs.Regs) u32 {
        const process = !r.handlerMode() and b.control & regs.control_bits.spsel != 0;
        return if (process) b.psp else b.msp;
    }

    /// MRS of a _NS register from Secure state; null for anything else.
    pub fn readNs(self: *const Banked, r: *const regs.Regs, code: u8) ?u32 {
        if (self.current != .secure) return null;
        const b = self.other;
        return switch (code) {
            sysm.msp_ns => b.msp,
            sysm.psp_ns => b.psp,
            sysm.msplim_ns => b.msplim,
            sysm.psplim_ns => b.psplim,
            sysm.primask_ns => b.primask,
            sysm.basepri_ns => b.basepri,
            sysm.faultmask_ns => b.faultmask,
            sysm.control_ns => b.control,
            sysm.sp_ns => spNs(b, r),
            else => null,
        };
    }

    /// MSR of a _NS register from Secure state, keeping only the bits the
    /// architecture implements (SP and limits are 8-byte limits, 4-byte
    /// pointers). Returns false when `code` is not one this handles.
    pub fn writeNs(self: *Banked, r: *const regs.Regs, code: u8, value: u32) bool {
        if (self.current != .secure) return false;
        const b = &self.other;
        switch (code) {
            sysm.msp_ns => b.setMsp(value & ~@as(u32, 3)),
            sysm.psp_ns => b.setPsp(value & ~@as(u32, 3)),
            sysm.msplim_ns => b.msplim = value & ~@as(u32, 7),
            sysm.psplim_ns => b.psplim = value & ~@as(u32, 7),
            sysm.primask_ns => b.primask = value & 1,
            sysm.basepri_ns => b.basepri = value & 0xFF,
            sysm.faultmask_ns => b.faultmask = value & 1,
            sysm.control_ns => b.control = value & control_banked,
            sysm.sp_ns => {
                const process = !r.handlerMode() and b.control & regs.control_bits.spsel != 0;
                if (process) b.setPsp(value & ~@as(u32, 3)) else b.setMsp(value & ~@as(u32, 3));
            },
            else => return false,
        }
        return true;
    }
};
