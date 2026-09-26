//! The USBHS controller in host role: the window at 0x40351000, the register
//! file behind it, and the bring-up the firmware's polled host driver walks.
//!
//! This is the controller's bring-up half. The power machine lives in
//! usbhs_phy.zig and the pipe table in usbhs_pipe.zig; what is here is the
//! window: which offsets are real registers, which answer from the machine
//! rather than the shadow, and which a store cannot reach at all. The
//! transfers themselves (CFIFO staging, SETUP, the device bridge) are the
//! next slice.
const periph = @import("registry.zig");
const regs = @import("usbhs_regs.zig");
const usbhs_phy = @import("usbhs_phy.zig");
const usbhs_pipe = @import("usbhs_pipe.zig");

pub const Host = struct {
    base: u32 = regs.window.base,
    phy: usbhs_phy.Phy = .{},
    pipes: usbhs_pipe.Table = .{},
    /// The 16-bit register shadow, for everything the model does not own.
    shadow: [regs.window.words]u16 = .{0} ** regs.window.words,

    /// Accesses refused, each for its own reason.
    misaligned: u32 = 0,
    off: u32 = 0,
    read_only: u32 = 0,

    /// Say something is on the far end of the cable, the way plugging one in
    /// would.
    pub fn attachDevice(self: *Host) void {
        self.phy.attached = true;
    }

    fn word(offset: u32) u32 {
        return offset / regs.window.word;
    }

    /// Every register in this window is 16 bits on a 16-bit boundary. dev
    /// masked the low bit off and answered anyway, so a byte access at an odd
    /// address read a whole neighbouring register and a store at one landed
    /// on it.
    fn aligned(self: *Host, offset: u32) bool {
        if (offset % regs.window.word == 0 and offset < regs.window.span) return true;
        self.misaligned += 1;
        return false;
    }

    /// Reachable with the module off: SYSCFG itself (or it could never be
    /// turned on) and the PHY page, which is per-window state the device role
    /// shares.
    fn alwaysOn(offset: u32) bool {
        return offset == regs.reg.syscfg or offset >= regs.reg.phy_page;
    }

    pub fn read(self: *Host, address: u32, width: u3) u32 {
        _ = width;
        const offset = address -% self.base;
        if (!self.aligned(offset)) return 0;
        if (offset == regs.reg.pllsta) return self.phy.pllLock();
        if (!alwaysOn(offset) and !self.phy.powered()) {
            self.off += 1;
            return 0;
        }
        return switch (offset) {
            regs.reg.syscfg => self.phy.syscfg,
            regs.reg.syssts0 => self.phy.lineState(),
            regs.reg.dvstctr0 => self.phy.portStatus(),
            regs.reg.pipesel => self.pipes.selected,
            regs.reg.pipecfg => self.pipes.config(),
            regs.reg.pipemaxp => self.pipes.maxPacket(),
            else => if (regs.isPipeCtr(offset))
                self.pipes.control(regs.pipeCtrIndex(offset))
            else
                self.shadow[word(offset)],
        };
    }

    pub fn write(self: *Host, address: u32, width: u3, value: u32) void {
        _ = width;
        const offset = address -% self.base;
        if (!self.aligned(offset)) return;
        const v: u16 = @truncate(value);
        if (offset == regs.reg.syscfg) {
            self.phy.setSyscfg(v);
            return;
        }
        if (!alwaysOn(offset) and !self.phy.powered()) {
            self.off += 1;
            return;
        }
        switch (offset) {
            // What the port found is the port's to report, not the driver's
            // to set. dev let both land in the shadow and read back.
            regs.reg.syssts0, regs.reg.pllsta => {
                self.read_only += 1;
                self.phy.refuseStatus();
            },
            regs.reg.dvstctr0 => _ = self.phy.setPort(v),
            regs.reg.pipesel => self.pipes.select(v),
            regs.reg.pipecfg => _ = self.pipes.configure(v),
            regs.reg.pipemaxp => _ = self.pipes.setMaxPacket(v),
            // W0C: a status bit clears by writing zero to it.
            regs.reg.intsts0,
            regs.reg.intsts1,
            regs.reg.brdysts,
            regs.reg.nrdysts,
            regs.reg.bempsts,
            => self.shadow[word(offset)] &= v,
            else => {
                if (regs.isPipeCtr(offset)) {
                    _ = self.pipes.setControl(regs.pipeCtrIndex(offset), v);
                    return;
                }
                self.shadow[word(offset)] = v;
            },
        }
    }

    pub fn refusals(self: *const Host) u32 {
        return self.misaligned + self.off + self.read_only +
            self.phy.refusals() + self.pipes.refusals();
    }

    pub fn quiet(self: *const Host) bool {
        return self.phy.quiet() and self.pipes.quiet() and self.refusals() == 0;
    }

    pub fn block(self: *Host) periph.Block {
        return .{
            .name = "USBHS-host",
            .base = self.base,
            .size = regs.window.span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Host = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Host = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
