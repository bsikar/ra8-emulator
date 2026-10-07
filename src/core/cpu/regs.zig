//! The architectural register file of one Armv8-M processor, as the Zig core
//! holds it: R0-R12, both stack pointers, LR, PC, xPSR, CONTROL and the three
//! mask registers.
//!
//! R13 is not a register of its own. It is whichever of MSP and PSP the
//! current mode selects, so reading or writing it through `get` and `set`
//! lands on the banked pointer the processor would use. Reading R15 here gives
//! the address of the instruction being executed; the +4 a Thumb instruction
//! sees when it names the PC is the executor's to add, because it depends on
//! the instruction and not on the register file.
//!
//! This is one Security state's worth of registers. The Secure and Non-secure
//! banks TrustZone needs are the system lane's to add on top of it.

/// The bits of xPSR the register file itself has to know about.
pub const xpsr_bits = struct {
    /// EPSR.T. Armv8-M only executes Thumb, so a clear T bit means the next
    /// fetch is an INVSTATE UsageFault.
    pub const thumb: u32 = 1 << 24;
    /// EPSR.B, set by a BTI-enabled indirect branch and cleared at its pad.
    pub const bti: u32 = 1 << 21;
    /// APSR.Q, the sticky saturation flag SSAT, USAT and the DSP forms set.
    pub const q: u32 = 1 << 27;
    /// APSR.GE[3:0], one bit per byte lane, set by the DSP parallel adds and
    /// subtracts and read by SEL.
    pub const ge: u32 = 0xF << ge_shift;
    pub const ge_shift: u5 = 16;
    /// IPSR, the exception being handled; zero in Thread mode.
    pub const ipsr: u32 = 0x1FF;
};

pub const control_bits = struct {
    pub const npriv: u32 = 1 << 0;
    pub const spsel: u32 = 1 << 1;
    /// An FP context is active: the next exception stacks the extended frame.
    pub const fpca: u32 = 1 << 2;
    /// Secure FP context is active, as carried in FPCXT payloads.
    pub const sfpa: u32 = 1 << 3;
    /// Pointer authentication and branch target identification enable bits.
    pub const bti_en: u32 = 1 << 4;
    pub const ubti_en: u32 = 1 << 5;
    pub const pac_en: u32 = 1 << 6;
    pub const upac_en: u32 = 1 << 7;
};

/// The registers by name. R0-R15 come first, in order, so a register number
/// and its name share a value.
pub const Name = enum(u5) {
    r0,
    r1,
    r2,
    r3,
    r4,
    r5,
    r6,
    r7,
    r8,
    r9,
    r10,
    r11,
    r12,
    sp,
    lr,
    pc,
    msp,
    psp,
    xpsr,
    control,
    primask,
    basepri,
    faultmask,
};

pub const Regs = struct {
    low: [13]u32 = @splat(0),
    msp: u32 = 0,
    psp: u32 = 0,
    lr: u32 = 0,
    pc: u32 = 0,
    xpsr: u32 = 0,
    control: u32 = 0,
    primask: u32 = 0,
    basepri: u32 = 0,
    faultmask: u32 = 0,
    /// The stack limits MSR and MRS reach. Bits 2:0 are RES0.
    msplim: u32 = 0,
    psplim: u32 = 0,
    /// The privileged and unprivileged 128-bit PAC keys for this Security
    /// state. Word 3 is the most significant key word (DDI0553 SYSm 0x20-27).
    pac_key_p: [4]u32 = .{ 0, 0, 0, 0 },
    pac_key_u: [4]u32 = .{ 0, 0, 0, 0 },
    /// An EXC_RETURN value a PC write in Handler mode left for the core to
    /// act on once the instruction retires (src/core/cpu/exception/ret.zig).
    exc_return: ?u32 = null,
    /// An FNC_RETURN value a PC write left for the core to act on once the
    /// instruction retires (src/core/cpu/exception/fnc_return.zig).
    fnc_return: ?u32 = null,

    /// A register by number, the way an encoding names it.
    pub fn get(self: *const Regs, n: u4) u32 {
        return switch (n) {
            0...12 => self.low[n],
            13 => self.sp(),
            14 => self.lr,
            15 => self.pc,
        };
    }

    pub fn set(self: *Regs, n: u4, value: u32) void {
        switch (n) {
            0...12 => self.low[n] = value,
            13 => self.setSp(value),
            14 => self.lr = value,
            15 => self.pc = value,
        }
    }

    /// BXWritePC: bit 0 becomes EPSR.T, the rest the PC. LDR and POP to the
    /// PC write it this way. In Handler mode a value with bits 31:24 set is
    /// an exception return instead, and in any mode bits 31:24 of 0xFE are
    /// a function return (FNC_RETURN), each held for the core to perform.
    pub fn bxWritePc(self: *Regs, value: u32) void {
        if (self.handlerMode() and value >> 24 == 0xFF) {
            self.exc_return = value;
            return;
        }
        if (value >> 24 == 0xFE) {
            self.fnc_return = value;
            return;
        }
        const thumb = xpsr_bits.thumb;
        self.xpsr = if (value & 1 != 0) self.xpsr | thumb else self.xpsr & ~thumb;
        self.pc = value & ~@as(u32, 1);
    }

    pub fn handlerMode(self: *const Regs) bool {
        return self.xpsr & xpsr_bits.ipsr != 0;
    }

    /// Thread mode with CONTROL.SPSEL set runs on the Process stack; Handler
    /// mode always runs on the Main one.
    pub fn usesPsp(self: *const Regs) bool {
        return !self.handlerMode() and self.control & control_bits.spsel != 0;
    }

    pub fn sp(self: *const Regs) u32 {
        return if (self.usesPsp()) self.psp else self.msp;
    }

    /// The limit for R13 in the current mode and CONTROL.SPSEL state.
    pub fn spLimit(self: *const Regs) u32 {
        return if (self.usesPsp()) self.psplim else self.msplim;
    }

    /// SP[1:0] read as zero and ignore writes, on both banked pointers.
    pub fn setSp(self: *Regs, value: u32) void {
        const aligned = value & ~@as(u32, 3);
        if (self.usesPsp()) self.psp = aligned else self.msp = aligned;
    }

    pub fn read(self: *const Regs, name: Name) u32 {
        const n = @backingInt(name);
        if (n <= 15) return self.get(@intCast(n));
        return switch (name) {
            .msp => self.msp,
            .psp => self.psp,
            .xpsr => self.xpsr,
            .control => self.control,
            .primask => self.primask,
            .basepri => self.basepri,
            .faultmask => self.faultmask,
            else => unreachable,
        };
    }

    /// Write a register by name, keeping only the bits the architecture
    /// implements: one for PRIMASK and FAULTMASK, eight for BASEPRI.
    pub fn write(self: *Regs, name: Name, value: u32) void {
        const n = @backingInt(name);
        if (n <= 15) return self.set(@intCast(n), value);
        switch (name) {
            .msp => self.msp = value & ~@as(u32, 3),
            .psp => self.psp = value & ~@as(u32, 3),
            .xpsr => self.xpsr = value,
            .control => self.control = value,
            .primask => self.primask = value & 1,
            .basepri => self.basepri = value & 0xFF,
            .faultmask => self.faultmask = value & 1,
            else => unreachable,
        }
    }
};
