//! The cable between the two jacks on a self-loop board: what the USBHS host
//! sends reaches the USBFS device model, and what the USBFS driver commits
//! comes back to the host.
//!
//! usb_selftest_cdc runs a device stack on USBFS and a host stack on USBHS,
//! cabled together. This is the far end the USBHS host sees in that case, in
//! place of the stand-in device in usbhs_device.zig. It answers nothing on
//! its own: every reply is a packet the firmware's own USBFS driver wrote.
//! A control transfer is asynchronous here, because the device side answers
//! only when its driver runs, so the host side polls `answer`.
const usbfs = @import("../usbfs/usbfs.zig");
const regs = @import("usbhs_regs.zig");

/// How the device side has ended the control transfer so far.
pub const Answer = enum { pending, ack, stall };

pub const Loop = struct {
    device: *usbfs.Device,
    setups: u32 = 0,
    ins: u32 = 0,
    outs: u32 = 0,
    bulk_ins: u32 = 0,
    bulk_outs: u32 = 0,
    /// Bulk tokens for an endpoint the device driver opened no pipe for.
    unopened: u32 = 0,

    /// A SETUP from the host lands on the device's DCP.
    pub fn setup(self: *Loop, packet: [8]u8) void {
        self.device.setup(packet);
        self.setups += 1;
    }

    /// An IN token on the control pipe: the packet the device driver last
    /// committed with BVAL, or null while it has committed none.
    pub fn takeIn(self: *Loop, into: []u8) ?u16 {
        const len = self.device.control.hostTake(into) orelse return null;
        self.ins += 1;
        return len;
    }

    /// An OUT data packet on the control pipe, for the device driver to read.
    pub fn out(self: *Loop, bytes: []const u8) void {
        self.device.control.hostOut(bytes);
        self.outs += 1;
    }

    /// The status-stage token after a data stage.
    pub fn statusStage(self: *Loop) void {
        self.device.statusStage();
    }

    /// Ack once the driver has set CCPL and CTSQ is back at idle, stall when
    /// it set the DCP PID to STALL, pending while it has done neither.
    pub fn answer(self: *Loop) Answer {
        const pid = self.device.read(self.device.base + regs.reg.dcpctr, 2);
        if (pid & regs.dcpctr.pid_stall != 0) return .stall;
        const stage = self.device.interruptStatus() & usbfs.intsts0.ctsq_mask;
        if (stage == usbfs.intsts0.ctsq_idle) return .ack;
        return .pending;
    }

    /// A bulk or interrupt OUT packet for an endpoint. True once it sits in
    /// the device pipe's buffer; false is a NAK: no pipe opened for the
    /// endpoint, or the driver has not drained the last packet yet.
    pub fn bulkOut(self: *Loop, endpoint: u4, bytes: []const u8) bool {
        const device = self.device;
        const n = device.pipes.find(endpoint, false) orelse {
            self.unopened += 1;
            return false;
        };
        if (!device.endpoints.hostOut(&device.pipes, n, bytes)) return false;
        self.bulk_outs += 1;
        return true;
    }

    /// A bulk or interrupt IN token for an endpoint: the packet the device
    /// driver committed on that endpoint's pipe, or null (a NAK) while it
    /// has committed none.
    pub fn bulkIn(self: *Loop, endpoint: u4, into: []u8) ?u16 {
        const n = self.device.pipes.find(endpoint, true) orelse {
            self.unopened += 1;
            return null;
        };
        const len = self.device.endpoints.hostTake(n, into) orelse return null;
        self.bulk_ins += 1;
        return len;
    }

    /// The device's state as the host would learn it: Default, Address or
    /// Configured, from DVSQ.
    pub fn deviceState(self: *const Loop) u16 {
        return self.device.interruptStatus() & usbfs.intsts0.dvsq_mask;
    }
};
