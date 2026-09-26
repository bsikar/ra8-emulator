//! The USBHS controller in host role: the window at 0x40351000, the register
//! file behind it, and the bring-up the firmware's polled host driver walks.
//!
//! What is here is the window: which offsets are real registers, which answer
//! from a machine rather than the shadow, and which a store cannot reach at
//! all. The machines themselves live beside it: the power and port side in
//! usbhs_phy.zig, the pipe table in usbhs_pipe.zig, and the control transfer
//! (CFIFO staging, SETUP, the device on the far end) in usbhs_xfer.zig.
const periph = @import("registry.zig");
const regs = @import("usbhs_regs.zig");
const usbhs_phy = @import("usbhs_phy.zig");
const usbhs_pipe = @import("usbhs_pipe.zig");
const usbhs_xfer = @import("usbhs_xfer.zig");

pub const Host = struct {
    base: u32 = regs.window.base,
    phy: usbhs_phy.Phy = .{},
    pipes: usbhs_pipe.Table = .{},
    xfer: usbhs_xfer.Transfer = .{},
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
        const offset = address -% self.base;
        if (!self.aligned(offset)) return 0;
        if (offset == regs.reg.pllsta) return self.phy.pllLock();
        if (!alwaysOn(offset) and !self.phy.powered()) {
            self.off += 1;
            return 0;
        }
        if (isFifoPort(offset)) return self.xfer.port.readData(width);
        return switch (offset) {
            regs.reg.syscfg => self.phy.syscfg,
            regs.reg.syssts0 => self.phy.lineState(),
            regs.reg.dvstctr0 => self.phy.portStatus(),
            regs.reg.pipesel => self.pipes.selected,
            regs.reg.pipecfg => self.pipes.config(),
            regs.reg.pipemaxp => self.pipes.maxPacket(),
            regs.reg.cfifosel => self.xfer.port.sel,
            regs.reg.cfifoctr => self.xfer.port.status(),
            regs.reg.brdysts => self.xfer.readyStatus(&self.pipes),
            regs.reg.bempsts => self.xfer.bemp,
            regs.reg.intsts1 => self.xfer.intsts1,
            regs.reg.dcpctr => self.xfer.dcpctr,
            regs.reg.usbreq => self.xfer.usbreq,
            regs.reg.usbval => self.xfer.usbval,
            regs.reg.usbindx => self.xfer.usbindx,
            regs.reg.usbleng => self.xfer.usbleng,
            else => if (regs.isPipeCtr(offset))
                self.pipes.control(regs.pipeCtrIndex(offset))
            else
                self.shadow[word(offset)],
        };
    }

    pub fn write(self: *Host, address: u32, width: u3, value: u32) void {
        const offset = address -% self.base;
        if (!self.aligned(offset)) return;
        const v: u16 = @truncate(value);
        if (isFifoPort(offset)) {
            if (!self.phy.powered()) {
                self.off += 1;
                return;
            }
            self.xfer.port.writeData(value, width, self.selectedMaxPacket());
            return;
        }
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
            regs.reg.dvstctr0 => self.setPort(v),
            regs.reg.cfifosel => self.xfer.port.select(v),
            regs.reg.cfifoctr => self.fifoControl(v),
            regs.reg.dcpctr => self.controlPipe(v),
            regs.reg.brdysts => self.xfer.clearReady(v),
            regs.reg.bempsts => self.xfer.clearEmpty(v),
            regs.reg.intsts1 => self.xfer.intsts1 &= v,
            regs.reg.usbreq => self.xfer.usbreq = v,
            regs.reg.usbval => self.xfer.usbval = v,
            regs.reg.usbindx => self.xfer.usbindx = v,
            regs.reg.usbleng => self.xfer.usbleng = v,
            regs.reg.pipesel => self.pipes.select(v),
            regs.reg.pipecfg => _ = self.pipes.configure(v),
            regs.reg.pipemaxp => _ = self.pipes.setMaxPacket(v),
            // W0C: a status bit clears by writing zero to it.
            regs.reg.intsts0, regs.reg.nrdysts => self.shadow[word(offset)] &= v,
            else => {
                if (regs.isPipeCtr(offset)) {
                    _ = self.pipes.setControl(regs.pipeCtrIndex(offset), v);
                    return;
                }
                self.shadow[word(offset)] = v;
            },
        }
    }

    /// The CFIFO data port. Every access to it is 8, 16 or 32 bits wide at
    /// the same two words: the byte aliases dev modelled as separate offsets
    /// (CFIFOH, CFIFOHH) are inside these, reached by the access width.
    fn isFifoPort(offset: u32) bool {
        return offset == regs.reg.cfifo or offset == regs.reg.cfifo + regs.window.word;
    }

    /// What the pipe the FIFO port is aimed at may carry. The control pipe
    /// takes a descriptor-sized packet; a bulk pipe takes what the host
    /// programmed into PIPEMAXP.
    fn selectedMaxPacket(self: *Host) u16 {
        const index = self.xfer.port.pipe() orelse return 0;
        if (index == 0) return regs.staging.reply_cap;
        return self.pipes.pipes[index].maxp;
    }

    /// DVSTCTR0. A reset released on the port puts the device back in
    /// Default, the way unplugging and replugging it would.
    fn setPort(self: *Host, value: u16) void {
        const released = self.phy.setPort(value);
        if (released) self.xfer.busReset();
    }

    /// CFIFOCTR: BCLR throws the aimed-at buffer away, BVAL hands a staged
    /// OUT packet to the device.
    fn fifoControl(self: *Host, value: u16) void {
        if (value & regs.fifo.bclr != 0) self.xfer.port.clear();
        if (value & regs.fifo.bval != 0) self.xfer.commit(&self.pipes);
    }

    /// DCPCTR: SUREQ sends the staged SETUP, CCPL closes the transfer. SUREQ
    /// self-clears once the token is away and is never latched.
    fn controlPipe(self: *Host, value: u16) void {
        if (value & regs.dcpctr.sureq != 0) self.xfer.launch(self.live());
        if (value & regs.dcpctr.ccpl != 0 and self.xfer.dcpctr & regs.dcpctr.ccpl == 0) {
            self.xfer.complete();
        }
        self.xfer.dcpctr = value & ~regs.dcpctr.sureq;
    }

    /// There is something on the bus that has been through a port reset.
    fn live(self: *const Host) bool {
        return self.phy.attached and self.phy.speed != .none and self.phy.host();
    }

    pub fn refusals(self: *const Host) u32 {
        return self.misaligned + self.off + self.read_only +
            self.phy.refusals() + self.pipes.refusals() + self.xfer.refusals();
    }

    pub fn quiet(self: *const Host) bool {
        return self.phy.quiet() and self.pipes.quiet() and self.xfer.quiet() and
            self.refusals() == 0;
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
