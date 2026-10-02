//! The USBFS device window: VBUS, the line state after the pull-up, the
//! INTSTS0 flags a driver clears, and the shadow behind the rest.
const std = @import("std");
const ra8 = @import("ra8");
const usbfs = ra8.periph.usbfs;
const regs = ra8.periph.usbhs_regs;

fn at(offset: u32) u32 {
    return usbfs.window.base + offset;
}

test "the window is the controller's own" {
    var device = usbfs.Device{};
    const block = device.block();
    try std.testing.expectEqual(@as(u32, 0x4025_0000), block.base);
    try std.testing.expect(block.covers(at(regs.reg.dcpctr)));
    try std.testing.expect(!block.covers(usbfs.window.base + usbfs.window.span));
}

test "the line stays SE0 until the device pulls D+ up with VBUS present" {
    var device = usbfs.Device{};
    device.write(at(regs.reg.syscfg), 2, regs.syscfg.usbe | regs.syscfg.dprpu);
    try std.testing.expectEqual(@as(u32, 0), device.read(at(regs.reg.syssts0), 2));
    device.connectVbus();
    try std.testing.expectEqual(@as(u32, regs.port.lnst_j), device.read(at(regs.reg.syssts0), 2));
}

test "host role sees no device-side J-state" {
    var device = usbfs.Device{};
    device.connectVbus();
    device.write(at(regs.reg.syscfg), 2, regs.syscfg.usbe | regs.syscfg.dprpu | regs.syscfg.dcfm);
    try std.testing.expectEqual(@as(u32, 0), device.read(at(regs.reg.syssts0), 2));
}

test "VBUS latches VBINT and VBSTS follows the jack" {
    var device = usbfs.Device{};
    try std.testing.expectEqual(@as(u32, 0), device.read(at(regs.reg.intsts0), 2));
    device.connectVbus();
    const status = device.read(at(regs.reg.intsts0), 2);
    try std.testing.expect(status & usbfs.intsts0.vbint != 0);
    try std.testing.expect(status & usbfs.intsts0.vbsts != 0);
}

test "writing 0 clears VBINT; VBSTS cannot be cleared" {
    var device = usbfs.Device{};
    device.connectVbus();
    device.write(at(regs.reg.intsts0), 2, ~@as(u32, usbfs.intsts0.vbint));
    const status = device.read(at(regs.reg.intsts0), 2);
    try std.testing.expectEqual(@as(u32, 0), status & usbfs.intsts0.vbint);
    try std.testing.expect(status & usbfs.intsts0.vbsts != 0);
}

test "SYSSTS0 refuses a store" {
    var device = usbfs.Device{};
    device.write(at(regs.reg.syssts0), 2, 0xFFFF);
    try std.testing.expectEqual(@as(u32, 1), device.refusals());
    try std.testing.expectEqual(@as(u32, 0), device.read(at(regs.reg.syssts0), 2));
}

test "everything else reads back what was written" {
    var device = usbfs.Device{};
    device.write(at(regs.reg.dcpmaxp), 2, 0x0040);
    device.write(at(regs.reg.intenb0), 2, 0x9C00);
    try std.testing.expectEqual(@as(u32, 0x0040), device.read(at(regs.reg.dcpmaxp), 2));
    try std.testing.expectEqual(@as(u32, 0x9C00), device.read(at(regs.reg.intenb0), 2));
}

test "an odd address is refused" {
    var device = usbfs.Device{};
    device.write(at(0x21), 1, 0xAA);
    try std.testing.expectEqual(@as(u32, 0), device.read(at(0x21), 1));
    try std.testing.expectEqual(@as(u32, 2), device.refusals());
}
