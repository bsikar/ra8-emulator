//! The controller's power and port side: whether it is on, whose role it is
//! playing, and what the port reset settled on.
//!
//! dev answered the host's registers whatever SYSCFG said, and reported the
//! PHY PLL locked from the first read, so an image that never turned the
//! module or its clock on enumerated a device in the emulator and did nothing
//! on the bench. The machine here has to be brought up the way silicon is.
const regs = @import("usbhs_regs.zig");

/// What the port settled on after a reset, which is what DVSTCTR0.RHST
/// reports and what a driver picks its packet sizes from.
pub const Speed = enum {
    none,
    full,
    high,

    pub fn rhst(self: Speed) u16 {
        return switch (self) {
            .none => 0,
            .full => regs.port.rhst_full,
            .high => regs.port.rhst_high,
        };
    }
};

/// The power machine: SYSCFG, the PLL, the line state and the reset edge.
pub const Phy = struct {
    syscfg: u16 = 0,
    dvstctr0: u16 = 0,
    /// Whether anything is on the far end of the modelled cable.
    attached: bool = false,
    /// The speed the last completed reset settled on; none until one runs.
    speed: Speed = .none,
    /// Port resets the host drove to completion.
    resets: u32 = 0,

    /// Accesses refused, each for its own reason.
    off: u32 = 0,
    not_host: u32 = 0,
    read_only: u32 = 0,

    /// The module is on and clocked. Everything but SYSCFG itself is gated on
    /// this, or the firmware could never turn it on.
    pub fn powered(self: *const Phy) bool {
        return self.syscfg & regs.syscfg.usbe != 0 and self.syscfg & regs.syscfg.scke != 0;
    }

    /// DCFM: this controller is driving the bus, not answering on it. A host
    /// register means nothing while the part is in device role.
    pub fn host(self: *const Phy) bool {
        return self.syscfg & regs.syscfg.dcfm != 0;
    }

    /// The PLL locks once the module has its clock, and not before. dev
    /// returned the lock flag unconditionally, so a driver that polled it
    /// before enabling SCKE ran straight past the wait.
    pub fn pllLock(self: *const Phy) u16 {
        return if (self.powered()) regs.pllsta.plllock else 0;
    }

    /// The line state is the cable's to report, not the driver's to set.
    pub fn lineState(self: *const Phy) u16 {
        if (!self.powered() or !self.attached) return 0;
        return regs.port.lnst_j;
    }

    pub fn portStatus(self: *const Phy) u16 {
        return (self.dvstctr0 & ~regs.port.rhst_mask) | self.speed.rhst();
    }

    pub fn setSyscfg(self: *Phy, value: u16) void {
        self.syscfg = value;
        if (!self.powered()) {
            self.speed = .none;
            self.dvstctr0 &= ~regs.port.uact;
        }
    }

    /// A reset ends when the host releases USBRST, and only then does the
    /// port know its speed. dev never watched the edge at all on this side.
    pub fn setPort(self: *Phy, value: u16) bool {
        if (!self.powered()) {
            self.off += 1;
            return false;
        }
        if (!self.host()) {
            self.not_host += 1;
            return false;
        }
        const was = self.dvstctr0 & regs.port.usbrst != 0;
        const now = value & regs.port.usbrst != 0;
        self.dvstctr0 = value;
        if (was and !now) self.finishReset();
        return true;
    }

    fn finishReset(self: *Phy) void {
        self.resets += 1;
        self.speed = if (self.attached) .high else .none;
    }

    /// A status register a store cannot reach. SYSSTS0 is the line, RHST is
    /// what the reset found; dev let both be written and read back.
    pub fn refuseStatus(self: *Phy) void {
        self.read_only += 1;
    }

    pub fn quiet(self: *const Phy) bool {
        return self.resets == 0 and self.refusals() == 0;
    }

    pub fn refusals(self: *const Phy) u32 {
        return self.off + self.not_host + self.read_only;
    }
};
