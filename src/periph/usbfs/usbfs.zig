//! The USBFS controller in device role: the window at 0x40250000 and the
//! registers a device driver reads back during bring-up.
//!
//! USBFS shares its register layout with USBHS (ra8_usb_regs.h), so the
//! offsets come from usbhs_regs.zig. What differs is the role: this side is
//! the device half of the board's USB loop, so what it reports is whether
//! VBUS is present and what the line looks like once the driver pulls D+ up.
//!
//! Everything the model does not own lands in a 16-bit shadow and reads back,
//! which is what the sparse register file did, minus the alternating
//! 0/all-ones answers to reads.
const std = @import("std");
const periph = @import("../registry.zig");
const regs = @import("../usbhs/usbhs_regs.zig");

pub const window = struct {
    pub const base: u32 = 0x4025_0000;
    pub const span: u32 = 0x200;
    pub const word: u32 = 2;
    pub const words: u32 = span / word;
};

/// INTSTS0: the bits a device driver polls and clears.
pub const intsts0 = struct {
    pub const vbint: u16 = 1 << 15;
    pub const resm: u16 = 1 << 14;
    pub const sofr: u16 = 1 << 13;
    pub const dvst: u16 = 1 << 12;
    pub const ctrt: u16 = 1 << 11;
    pub const vbsts: u16 = 1 << 7;
    pub const valid: u16 = 1 << 3;
    /// DVSQ[2:0]: the device state the controller tracks on its own.
    pub const dvsq_mask: u16 = 0x0070;
    pub const dvsq_powered: u16 = 0x0000;
    pub const dvsq_default: u16 = 0x0010;
    /// Status flags the driver clears by writing 0; a 1 leaves them alone.
    /// CTSQ[2:0]: the control-transfer stage the controller is in.
    pub const ctsq_mask: u16 = 0x0007;
    pub const ctsq_read_data: u16 = 0b001;
    pub const ctsq_write_data: u16 = 0b011;
    pub const ctsq_no_data_status: u16 = 0b101;
    pub const write_zero_clears: u16 = vbint | resm | sofr | dvst | ctrt | valid;
};

pub const Device = struct {
    base: u32 = window.base,
    /// VBUS on the device jack. A board fact: the self-loop apps cable the
    /// two jacks together, so the board says when it is there.
    vbus: bool = false,
    syscfg: u16 = 0,
    status: u16 = 0,
    shadow: [window.words]u16 = .{0} ** window.words,

    /// Accesses refused, each for its own reason.
    misaligned: u32 = 0,
    read_only: u32 = 0,

    /// Power the jack, the way plugging a cable in would. VBINT latches the
    /// change for the driver to see.
    pub fn connectVbus(self: *Device) void {
        defer self.settle();
        if (!self.vbus) self.status |= intsts0.vbint;
        self.vbus = true;
    }

    /// A SETUP packet from the host on the other jack lands on the DCP:
    /// USBREQ, USBVAL, USBINDX and USBLENG take its four fields, VALID and
    /// CTRT latch, and CTSQ moves to the stage the request asks for.
    pub fn setup(self: *Device, packet: [8]u8) void {
        const field = std.mem.readInt;
        self.shadow[regs.reg.usbreq / window.word] = field(u16, packet[0..2], .little);
        self.shadow[regs.reg.usbval / window.word] = field(u16, packet[2..4], .little);
        self.shadow[regs.reg.usbindx / window.word] = field(u16, packet[4..6], .little);
        const length = field(u16, packet[6..8], .little);
        self.shadow[regs.reg.usbleng / window.word] = length;
        const stage = if (packet[0] & 0x80 != 0)
            intsts0.ctsq_read_data
        else if (length != 0)
            intsts0.ctsq_write_data
        else
            intsts0.ctsq_no_data_status;
        self.status = (self.status & ~intsts0.ctsq_mask) | stage | intsts0.valid | intsts0.ctrt;
    }

    fn attached(self: *const Device) bool {
        return self.lineState() == regs.port.lnst_j and self.syscfg & regs.syscfg.usbe != 0;
    }

    /// The host on the other jack resets the bus as soon as it sees the
    /// pull-up, so an attach lands straight in the Default state at full
    /// speed with DVST latched. Dropping the pull-up goes back to Powered.
    fn settle(self: *Device) void {
        const state = self.status & intsts0.dvsq_mask;
        const want = if (self.attached()) intsts0.dvsq_default else intsts0.dvsq_powered;
        if (state == want) return;
        self.status = (self.status & ~intsts0.dvsq_mask) | want | intsts0.dvst;
    }

    /// DVSTCTR0.RHST: full speed once the reset has put the device in a
    /// state past Powered. The rest of the register reads back from the
    /// shadow.
    pub fn portStatus(self: *const Device) u16 {
        const stored = self.shadow[regs.reg.dvstctr0 / window.word] & ~regs.port.rhst_mask;
        if (self.status & intsts0.dvsq_mask == intsts0.dvsq_powered) return stored;
        return stored | regs.port.rhst_full;
    }

    fn aligned(self: *Device, offset: u32) bool {
        if (offset % window.word == 0 and offset < window.span) return true;
        self.misaligned += 1;
        return false;
    }

    /// SYSSTS0.LNST: J-state once a device-role driver pulls D+ up with VBUS
    /// present, SE0 otherwise. Nothing drives K or a reset yet.
    pub fn lineState(self: *const Device) u16 {
        const device_role = self.syscfg & regs.syscfg.dcfm == 0;
        const pulled_up = self.syscfg & regs.syscfg.dprpu != 0;
        if (self.vbus and device_role and pulled_up) return regs.port.lnst_j;
        return 0;
    }

    pub fn interruptStatus(self: *const Device) u16 {
        const live: u16 = if (self.vbus) intsts0.vbsts else 0;
        return (self.status & ~intsts0.vbsts) | live;
    }

    pub fn read(self: *Device, address: u32, width: u3) u32 {
        _ = width;
        const offset = address -% self.base;
        if (!self.aligned(offset)) return 0;
        return switch (offset) {
            regs.reg.syscfg => self.syscfg,
            regs.reg.syssts0 => self.lineState(),
            regs.reg.intsts0 => self.interruptStatus(),
            regs.reg.dvstctr0 => self.portStatus(),
            else => self.shadow[offset / window.word],
        };
    }

    pub fn write(self: *Device, address: u32, width: u3, value: u32) void {
        _ = width;
        const offset = address -% self.base;
        if (!self.aligned(offset)) return;
        const v: u16 = @truncate(value);
        switch (offset) {
            regs.reg.syscfg => {
                self.syscfg = v;
                self.settle();
            },
            regs.reg.syssts0 => self.read_only += 1,
            regs.reg.usbreq, regs.reg.usbval, regs.reg.usbindx, regs.reg.usbleng => self.read_only += 1,
            regs.reg.intsts0 => self.status &= v | ~intsts0.write_zero_clears,
            else => self.shadow[offset / window.word] = v,
        }
    }

    pub fn refusals(self: *const Device) u32 {
        return self.misaligned + self.read_only;
    }

    pub fn block(self: *Device) periph.Block {
        return .{
            .name = "USBFS-device",
            .base = self.base,
            .size = window.span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Device = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Device = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
