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
    /// IPSR, the exception being handled; zero in Thread mode.
    pub const ipsr: u32 = 0x1FF;
};

pub const control_bits = struct {
    pub const npriv: u32 = 1 << 0;
    pub const spsel: u32 = 1 << 1;
};

/// The registers by name. R0-R15 come first, in order, so a register number
/// and its name share a value. The set is the one src/core/engine.zig names
/// for Unicorn, which is what lets a lockstep run compare the two backends
/// one name at a time.
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
    low: [13]u32 = [_]u32{0} ** 13,
    msp: u32 = 0,
    psp: u32 = 0,
    lr: u32 = 0,
    pc: u32 = 0,
    xpsr: u32 = 0,
    control: u32 = 0,
    primask: u32 = 0,
    basepri: u32 = 0,
    faultmask: u32 = 0,

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
    /// PC write it this way.
    pub fn bxWritePc(self: *Regs, value: u32) void {
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

    /// SP[1:0] read as zero and ignore writes, on both banked pointers.
    pub fn setSp(self: *Regs, value: u32) void {
        const aligned = value & ~@as(u32, 3);
        if (self.usesPsp()) self.psp = aligned else self.msp = aligned;
    }

    pub fn read(self: *const Regs, name: Name) u32 {
        const n = @intFromEnum(name);
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
        const n = @intFromEnum(name);
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
