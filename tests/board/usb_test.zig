//! Tests for src/board/usb.zig: the scripted host on the device jack and the
//! USBFS interrupt the board raises for it.
const std = @import("std");
const ra8 = @import("ra8");

const usb = ra8.board.usb;
const usbfs = ra8.periph.usbfs;
const regs = ra8.periph.usbhs_regs;

fn at(offset: u32) u32 {
    return usbfs.window.base + offset;
}

fn pulledUp() usb.Usb {
    var board = usb.Usb{};
    board.device.connectVbus();
    board.device.write(at(regs.reg.syscfg), 2, regs.syscfg.usbe | regs.syscfg.dprpu);
    board.device.write(at(regs.reg.intsts0), 2, ~@as(u32, usbfs.intsts0.dvst | usbfs.intsts0.vbint));
    return board;
}

test "no event while nothing is enabled" {
    var board = pulledUp();
    board.tick();
    board.tick();
    try std.testing.expectEqual(@as(usize, 0), board.dueEvents().len);
}

test "the host's first SETUP raises USBFS_INT once CTRE is enabled" {
    var board = pulledUp();
    board.device.write(at(regs.reg.intenb0), 2, usbfs.intsts0.ctrt);
    board.tick();
    board.tick();
    try std.testing.expectEqual(usbfs.host.Step.device_descriptor, board.script.step);
    const due = board.dueEvents();
    try std.testing.expectEqual(@as(usize, 1), due.len);
    try std.testing.expectEqual(usb.event.usbfs_int, due.get(0));
}

test "the line drops once the driver clears the cause" {
    var board = pulledUp();
    board.device.write(at(regs.reg.intenb0), 2, usbfs.intsts0.ctrt);
    board.tick();
    board.tick();
    board.device.write(at(regs.reg.intsts0), 2, ~@as(u32, usbfs.intsts0.ctrt));
    try std.testing.expectEqual(@as(usize, 0), board.dueEvents().len);
}

test "a disabled status bit raises nothing" {
    var board = pulledUp();
    board.device.write(at(regs.reg.intenb0), 2, usbfs.intsts0.vbint);
    board.tick();
    board.tick();
    try std.testing.expectEqual(@as(usize, 0), board.dueEvents().len);
}
