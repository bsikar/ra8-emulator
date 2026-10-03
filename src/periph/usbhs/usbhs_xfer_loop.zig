//! The USBHS transfer engine with the self-loop cable as its far end: the
//! answers the polled host sees come from the USBFS driver on the other
//! jack, not from the stand-in device.
//!
//! A control transfer is asynchronous on the cable. The SETUP goes across
//! at once, and every later answer appears only when the device driver has
//! run: a control-read packet once it commits one, a STALL once it sets
//! its DCP PID, a bulk-IN packet once it commits one on the endpoint's
//! pipe. BRDYSTS is the register the host spins on, so `ready` is called
//! from there and moves whatever the driver has committed since.
const regs = @import("usbhs_regs.zig");
const usbhs_fifo = @import("usbhs_fifo.zig");
const usbhs_loop = @import("usbhs_loop.zig");
const usbhs_pipe = @import("usbhs_pipe.zig");
const usbhs_setup = @import("usbhs_setup.zig");
const usbhs_xfer = @import("usbhs_xfer.zig");

/// The SETUP packet's eight wire bytes, little-endian fields.
pub fn bytes(packet: usbhs_setup.Packet) [8]u8 {
    return .{
        packet.request_type,      packet.code,
        @truncate(packet.value),  @truncate(packet.value >> 8),
        @truncate(packet.index),  @truncate(packet.index >> 8),
        @truncate(packet.length), @truncate(packet.length >> 8),
    };
}

/// BRDYSTS on the cable: the control reply, a device STALL, and a bulk-IN
/// packet on every armed IN pipe, each moved once the driver committed it.
pub fn ready(t: *usbhs_xfer.Transfer, cable: *usbhs_loop.Loop, pipes: *usbhs_pipe.Table) u16 {
    if (t.in_flight and cable.answer() == .stall) {
        t.stalls += 1;
        t.in_flight = false;
        t.dcpctr = (t.dcpctr & ~regs.dcpctr.pid_mask) | regs.dcpctr.pid_stall;
    }
    if (t.in_flight and t.control_read and fill(&t.port.in[0], cable, null)) {
        t.raiseReady(regs.status.dcp);
    }
    var index: u32 = 1;
    while (index < regs.pipe.count) : (index += 1) {
        const pipe = pipes.pipes[index];
        if (!pipe.armed() or !pipe.in) continue;
        if (!fill(&t.port.in[index], cable, @truncate(pipe.endpoint))) continue;
        t.raiseReady(@as(u16, 1) << @intCast(index));
    }
    return t.brdy;
}

/// Move one packet off the cable into an empty host buffer: the DCP's when
/// endpoint is null, otherwise that endpoint's pipe.
fn fill(staging: *usbhs_fifo.Staging, cable: *usbhs_loop.Loop, endpoint: ?u4) bool {
    if (staging.ready) return false;
    const len = if (endpoint) |ep|
        cable.bulkIn(ep, &staging.data)
    else
        cable.takeIn(&staging.data);
    staging.len = len orelse return false;
    staging.cursor = 0;
    staging.ready = true;
    return true;
}
