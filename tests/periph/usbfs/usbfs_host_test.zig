//! The scripted host on the USBFS jack, against a stand-in driver that
//! answers each request the way a device stack would.
const std = @import("std");
const ra8 = @import("ra8");
const usbfs = ra8.periph.usbfs;
const regs = ra8.periph.usbhs_regs;
const Host = usbfs.host.Host;

fn at(offset: u32) u32 {
    return usbfs.window.base + offset;
}

const device_descriptor = [18]u8{ 18, 1, 0x00, 0x02, 2, 0, 0, 64, 0x5B, 0x04, 0x01, 0x00, 0, 1, 1, 2, 3, 1 };
/// A whole configuration set: header, one interface, one bulk IN endpoint.
const config_descriptor = [25]u8{
    9, 2, 25,   0, 1,  1,    0, 0x80, 50,
    9, 4, 0,    0, 1,  0xFF, 0, 0,    0,
    7, 5, 0x81, 2, 64, 0,    0,
};

fn attached() usbfs.Device {
    var device = usbfs.Device{};
    device.connectVbus();
    device.write(at(regs.reg.syscfg), 2, regs.syscfg.usbe | regs.syscfg.dprpu);
    return device;
}

fn send(device: *usbfs.Device, bytes: []const u8) void {
    device.write(at(regs.reg.cfifosel), 2, regs.fifo.isel);
    for (bytes) |byte| device.write(at(regs.reg.cfifo), 1, byte);
    device.write(at(regs.reg.cfifoctr), 2, regs.fifo.bval);
}

/// Answer a pending SETUP: descriptors for GET_DESCRIPTOR, nothing for the
/// rest, then CCPL to end the status stage.
fn answer(device: *usbfs.Device) void {
    const status = device.read(at(regs.reg.intsts0), 2);
    if (status & usbfs.intsts0.valid == 0) return;
    device.write(at(regs.reg.intsts0), 2, ~@as(u32, usbfs.intsts0.valid));
    const request = device.read(at(regs.reg.usbreq), 2);
    const value = device.read(at(regs.reg.usbval), 2);
    const length = device.read(at(regs.reg.usbleng), 2);
    if (request == 0x0680 and value == 0x0100) send(device, &device_descriptor);
    if (request == 0x0680 and value == 0x0200) send(device, config_descriptor[0..@min(length, config_descriptor.len)]);
    device.write(at(regs.reg.dcpctr), 2, regs.dcpctr.ccpl | regs.dcpctr.pid_buf);
}

test "a device that answers is enumerated to Configured" {
    var device = attached();
    var host = Host{};
    var i: u32 = 0;
    while (i < 100 and !host.done()) : (i += 1) {
        host.tick(&device);
        answer(&device);
    }
    try std.testing.expect(host.done());
    try std.testing.expectEqualSlices(u8, &device_descriptor, &host.device);
    try std.testing.expectEqualSlices(u8, &config_descriptor, host.configuration());
    const status = device.read(at(regs.reg.intsts0), 2);
    try std.testing.expectEqual(@as(u32, usbfs.intsts0.dvsq_configured), status & usbfs.intsts0.dvsq_mask);
    try std.testing.expectEqual(@as(u32, usbfs.host.requests.address), device.read(at(regs.reg.usbaddr), 2));
}

test "the host waits while nothing pulls D+ up" {
    var device = usbfs.Device{};
    var host = Host{};
    host.tick(&device);
    host.tick(&device);
    try std.testing.expectEqual(usbfs.host.Step.waiting, host.step);
    try std.testing.expectEqual(@as(u32, 0), device.read(at(regs.reg.intsts0), 2) & usbfs.intsts0.valid);
}

test "a driver that never answers ends the script in failed" {
    var device = attached();
    var host = Host{ .patience = 5 };
    var i: u32 = 0;
    while (i < 20) : (i += 1) host.tick(&device);
    try std.testing.expectEqual(usbfs.host.Step.failed, host.step);
    try std.testing.expect(!host.done());
}

test "the host does not move on until the driver ends the status stage" {
    var device = attached();
    var host = Host{};
    host.tick(&device);
    host.tick(&device);
    send(&device, &device_descriptor);
    var i: u32 = 0;
    while (i < 5) : (i += 1) host.tick(&device);
    try std.testing.expectEqual(usbfs.host.Step.device_descriptor, host.step);
    device.write(at(regs.reg.dcpctr), 2, regs.dcpctr.ccpl);
    host.tick(&device);
    try std.testing.expectEqual(usbfs.host.Step.set_address, host.step);
}

test "once the data is in, the host sends the status token before waiting on CCPL" {
    var device = attached();
    var host = Host{};
    host.tick(&device);
    host.tick(&device);
    send(&device, &device_descriptor);
    host.tick(&device);
    host.tick(&device);
    const stage = device.interruptStatus() & usbfs.intsts0.ctsq_mask;
    try std.testing.expectEqual(usbfs.intsts0.ctsq_read_status, stage);
    try std.testing.expectEqual(usbfs.host.Step.device_descriptor, host.step);
}

test "the second configuration read asks for wTotalLength bytes" {
    const packet = usbfs.host.requests.configDescriptor(75);
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x06, 0x00, 0x02, 0x00, 0x00, 75, 0 }, &packet);
}

test "before the full read the host holds the nine-byte header" {
    var host = Host{};
    host.config[0] = 9;
    try std.testing.expectEqual(@as(usize, 9), host.configuration().len);
    host.config_len = 25;
    try std.testing.expectEqual(@as(usize, 25), host.configuration().len);
}
