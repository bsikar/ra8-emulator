//! The transfer half of the host controller: a SETUP launched, a data stage
//! staged through the CFIFO, and a status stage completed.
//!
//! dev drove this from the register handler itself, bridging each step into a
//! second emulated part and raising BRDY and BEMP as soon as it had made the
//! call, so the polled host ran ahead of a device that had not answered yet.
//! Here the control transfer is a value with a state, the flags follow the
//! device, and a step the transfer is not in is refused.
const regs = @import("usbhs_regs.zig");
const usbhs_device = @import("usbhs_device.zig");
const usbhs_fifo = @import("usbhs_fifo.zig");
const usbhs_pipe = @import("usbhs_pipe.zig");
const usbhs_setup = @import("usbhs_setup.zig");

pub const Transfer = struct {
    port: usbhs_fifo.Port = .{},
    device: usbhs_device.Device = .{},

    /// The SETUP staging registers, as the host wrote them.
    usbreq: u16 = 0,
    usbval: u16 = 0,
    usbindx: u16 = 0,
    usbleng: u16 = 0,

    /// The request in flight, and which way its data stage runs.
    packet: usbhs_setup.Packet = .{},
    control_read: bool = false,
    in_flight: bool = false,

    brdy: u16 = 0,
    bemp: u16 = 0,
    intsts1: u16 = 0,
    dcpctr: u16 = 0,

    setups: u32 = 0,
    stalls: u32 = 0,
    /// Steps refused, each for its own reason.
    no_device: u32 = 0,
    stray_ccpl: u32 = 0,
    unarmed: u32 = 0,

    /// DCPCTR.SUREQ: send the staged SETUP. A token needs something on the
    /// bus that has been through a reset; dev delivered it whatever the port
    /// said, so an image that never reset the port enumerated in the
    /// emulator and found nothing on a bench.
    pub fn launch(self: *Transfer, live: bool) void {
        if (!live) {
            self.no_device += 1;
            return;
        }
        self.packet = usbhs_setup.Packet.fromRegisters(
            self.usbreq,
            self.usbval,
            self.usbindx,
            self.usbleng,
        );
        self.control_read = self.packet.controlRead();
        self.in_flight = true;
        self.setups += 1;
        self.port.in[0].clear();
        if (!self.device.handle(self.packet)) {
            self.stalls += 1;
            self.in_flight = false;
            return;
        }
        // The SIE latches SACK when the device ACKs the token; the polled
        // host gates its next step on it.
        self.intsts1 |= regs.int1.sack;
    }

    /// DCPCTR.CCPL: the host closes the transfer. dev ran this on any write
    /// with the bit set, so a driver that left CCPL standing completed the
    /// same transfer on every store.
    pub fn complete(self: *Transfer) void {
        if (!self.in_flight) {
            self.stray_ccpl += 1;
            return;
        }
        self.in_flight = false;
        if (self.control_read) {
            self.bemp |= regs.status.dcp;
            return;
        }
        self.port.in[0].clear();
        self.port.in[0].ready = true;
        self.brdy |= regs.status.dcp;
    }

    /// BRDYSTS is the register the polled host spins on, so it is where the
    /// device's answers become visible: a control-read reply, and a bulk-IN
    /// packet on any pipe the host has armed.
    pub fn readyStatus(self: *Transfer, pipes: *usbhs_pipe.Table) u16 {
        if (self.device.reply_ready and !self.port.in[0].ready) {
            const len = self.device.takeReply(&self.port.in[0].data);
            self.port.in[0].len = len;
            self.port.in[0].cursor = 0;
            self.port.in[0].ready = true;
            self.brdy |= regs.status.dcp;
        }
        var index: u32 = 1;
        while (index < regs.pipe.count) : (index += 1) {
            if (!pipes.pipes[index].armed() or !pipes.pipes[index].in) continue;
            if (!self.device.echo_ready or self.port.in[index].ready) continue;
            const len = self.device.takeEcho(&self.port.in[index].data);
            self.port.in[index].len = len;
            self.port.in[index].cursor = 0;
            self.port.in[index].ready = true;
            self.brdy |= @as(u16, 1) << @intCast(index);
        }
        return self.brdy;
    }

    /// W0C, and a cleared bit re-arms that pipe for the next packet.
    pub fn clearReady(self: *Transfer, value: u16) void {
        self.brdy &= value;
    }

    /// CFIFOCTR.BVAL: hand the staged OUT bytes to the device. A pipe the
    /// host has not armed moves nothing: dev committed whatever PIPECTR
    /// said, so a packet went out on a pipe the driver had left NAKing.
    pub fn commit(self: *Transfer, pipes: *usbhs_pipe.Table) void {
        const index = self.port.pipe() orelse {
            self.port.bad_pipe += 1;
            return;
        };
        if (index != 0 and !pipes.pipes[index].armed()) {
            self.unarmed += 1;
            return;
        }
        const staging = &self.port.out[index];
        if (staging.len == 0) return;
        var packet: [regs.staging.packet_cap]u8 = undefined;
        const len = staging.drain(&packet);
        if (index == 0) {
            self.bemp |= regs.status.dcp;
            return;
        }
        if (!self.device.bulkOut(packet[0..len])) return;
        self.bemp |= @as(u16, 1) << @intCast(index);
    }

    pub fn clearEmpty(self: *Transfer, value: u16) void {
        self.bemp &= value;
    }

    /// USBRST released: the device drops back to Default and every staged
    /// packet on the bus goes with it.
    pub fn busReset(self: *Transfer) void {
        self.device.busReset();
        self.in_flight = false;
        self.brdy = 0;
        self.bemp = 0;
        for (&self.port.in) |*staging| staging.clear();
        for (&self.port.out) |*staging| staging.clear();
    }

    pub fn refusals(self: *const Transfer) u32 {
        return self.no_device + self.stray_ccpl + self.unarmed + self.stalls +
            self.port.refusals() + self.device.refusals();
    }

    pub fn quiet(self: *const Transfer) bool {
        return self.setups == 0 and self.refusals() == 0 and self.port.quiet();
    }
};
