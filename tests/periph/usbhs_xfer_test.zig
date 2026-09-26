//! The control transfer: a SETUP launched, a data stage drained, a status
//! stage completed, and the steps that are refused.
const std = @import("std");
const ra8 = @import("ra8");
const device = ra8.periph.usbhs_device;
const regs = ra8.periph.usbhs_regs;
const usbhs_pipe = ra8.periph.usbhs_pipe;
const xfer = ra8.periph.usbhs_xfer;

fn getDescriptor(transfer: *xfer.Transfer, kind: u16, length: u16) void {
    transfer.usbreq = 0x0680;
    transfer.usbval = kind;
    transfer.usbindx = 0;
    transfer.usbleng = length;
    transfer.launch(true);
}

test "a SETUP needs something on the bus that has been reset" {
    var transfer = xfer.Transfer{};
    transfer.usbreq = 0x0680;
    transfer.usbleng = 18;
    // dev delivered the token whatever the port said.
    transfer.launch(false);
    try std.testing.expectEqual(@as(u32, 1), transfer.no_device);
    try std.testing.expectEqual(@as(u32, 0), transfer.setups);
    try std.testing.expect(!transfer.in_flight);
}

test "an acked SETUP latches SACK" {
    var transfer = xfer.Transfer{};
    getDescriptor(&transfer, 0x0100, 18);
    try std.testing.expectEqual(@as(u32, 1), transfer.setups);
    try std.testing.expect(transfer.intsts1 & regs.int1.sack != 0);
    try std.testing.expect(transfer.control_read);
}

test "a stalled SETUP leaves no transfer in flight and no SACK" {
    var transfer = xfer.Transfer{};
    getDescriptor(&transfer, 0x0300, 4);
    try std.testing.expectEqual(@as(u32, 1), transfer.stalls);
    try std.testing.expectEqual(@as(u16, 0), transfer.intsts1);
    try std.testing.expect(!transfer.in_flight);
}

test "the device's answer shows up on the ready register the host polls" {
    var transfer = xfer.Transfer{};
    var pipes = usbhs_pipe.Table{};
    getDescriptor(&transfer, 0x0100, 18);
    const ready = transfer.readyStatus(&pipes);
    try std.testing.expect(ready & regs.status.dcp != 0);
    transfer.port.select(0);
    try std.testing.expectEqual(regs.fifo.frdy | 18, transfer.port.status());
    // The descriptor's own first two bytes: length 18, type 1.
    try std.testing.expectEqual(@as(u32, 0x0112), transfer.port.readData(2));
}

test "the answer is latched once, not on every poll" {
    var transfer = xfer.Transfer{};
    var pipes = usbhs_pipe.Table{};
    getDescriptor(&transfer, 0x0100, 18);
    _ = transfer.readyStatus(&pipes);
    transfer.port.select(0);
    _ = transfer.port.readData(4);
    _ = transfer.readyStatus(&pipes);
    try std.testing.expectEqual(@as(u16, 14), transfer.port.in[0].remaining());
}

test "a CCPL with nothing in flight is refused" {
    var transfer = xfer.Transfer{};
    // dev ran the status stage on any store with the bit set.
    transfer.complete();
    try std.testing.expectEqual(@as(u32, 1), transfer.stray_ccpl);
    try std.testing.expectEqual(@as(u16, 0), transfer.brdy);
}

test "a control write's status stage is a zero-length IN packet" {
    var transfer = xfer.Transfer{};
    transfer.usbreq = 0x0500; // SET_ADDRESS
    transfer.usbval = 5;
    transfer.usbleng = 0;
    transfer.launch(true);
    transfer.complete();
    try std.testing.expect(transfer.brdy & regs.status.dcp != 0);
    try std.testing.expectEqual(@as(u16, 0), transfer.port.in[0].remaining());
    try std.testing.expectEqual(@as(u8, 5), transfer.device.address);
}

test "a control read's status stage reports the buffer empty" {
    var transfer = xfer.Transfer{};
    getDescriptor(&transfer, 0x0100, 18);
    transfer.complete();
    try std.testing.expect(transfer.bemp & regs.status.dcp != 0);
}

test "a ready bit clears by writing zero to it" {
    var transfer = xfer.Transfer{};
    transfer.brdy = 0x0005;
    transfer.clearReady(0x0004);
    try std.testing.expectEqual(@as(u16, 0x0004), transfer.brdy);
}

test "a bulk packet on a pipe the host never armed moves nothing" {
    var transfer = xfer.Transfer{};
    var pipes = usbhs_pipe.Table{};
    transfer.port.select(regs.fifo.isel | 2);
    transfer.port.writeData(0x42, 1, 64);
    transfer.commit(&pipes);
    // dev committed whatever PIPECTR said, NAK included.
    try std.testing.expectEqual(@as(u32, 1), transfer.unarmed);
    try std.testing.expect(!transfer.device.echo_ready);
}

test "an armed bulk pipe delivers to a configured device and raises BEMP" {
    var transfer = xfer.Transfer{};
    var pipes = usbhs_pipe.Table{};
    transfer.usbreq = 0x0500;
    transfer.usbval = 3;
    transfer.launch(true);
    transfer.usbreq = 0x0900; // SET_CONFIGURATION
    transfer.usbval = 1;
    transfer.launch(true);
    _ = pipes.setControl(2, regs.pipe.pid_buf);
    transfer.port.select(regs.fifo.isel | 2);
    transfer.port.writeData(0x33221100, 4, 64);
    transfer.commit(&pipes);
    try std.testing.expect(transfer.bemp & (@as(u16, 1) << 2) != 0);
    try std.testing.expect(transfer.device.echo_ready);
}

test "the echo comes back on an armed IN pipe" {
    var transfer = xfer.Transfer{};
    var pipes = usbhs_pipe.Table{};
    transfer.usbreq = 0x0500;
    transfer.usbval = 3;
    transfer.launch(true);
    transfer.usbreq = 0x0900;
    transfer.usbval = 1;
    transfer.launch(true);
    _ = pipes.setControl(2, regs.pipe.pid_buf);
    transfer.port.select(regs.fifo.isel | 2);
    transfer.port.writeData(0xBEEF, 2, 64);
    transfer.commit(&pipes);
    pipes.pipes[2].in = true;
    const ready = transfer.readyStatus(&pipes);
    try std.testing.expect(ready & (@as(u16, 1) << 2) != 0);
    transfer.port.select(2);
    try std.testing.expectEqual(@as(u32, 0xBEEF), transfer.port.readData(2));
}

test "a bus reset clears the flags and the staging with the device" {
    var transfer = xfer.Transfer{};
    var pipes = usbhs_pipe.Table{};
    getDescriptor(&transfer, 0x0100, 18);
    _ = transfer.readyStatus(&pipes);
    transfer.busReset();
    try std.testing.expectEqual(@as(u16, 0), transfer.brdy);
    try std.testing.expectEqual(@as(u16, 0), transfer.port.in[0].len);
    try std.testing.expectEqual(device.State.default, transfer.device.state);
    try std.testing.expect(!transfer.in_flight);
}

test "a fresh transfer is quiet" {
    const transfer = xfer.Transfer{};
    try std.testing.expect(transfer.quiet());
    try std.testing.expectEqual(@as(u32, 0), transfer.refusals());
}
