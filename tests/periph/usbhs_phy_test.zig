//! The controller's power and port machine: what it takes to bring it up,
//! and what it refuses before then.
const std = @import("std");
const ra8 = @import("ra8");
const regs = ra8.periph.usbhs_regs;
const usbhs_phy = ra8.periph.usbhs_phy;

fn poweredHost() usbhs_phy.Phy {
    var phy = usbhs_phy.Phy{};
    phy.setSyscfg(regs.syscfg.usbe | regs.syscfg.scke | regs.syscfg.dcfm);
    return phy;
}

test "the PLL does not lock before the module has its clock" {
    var phy = usbhs_phy.Phy{};
    try std.testing.expectEqual(@as(u16, 0), phy.pllLock());
    phy.setSyscfg(regs.syscfg.usbe);
    try std.testing.expectEqual(@as(u16, 0), phy.pllLock());
    phy.setSyscfg(regs.syscfg.usbe | regs.syscfg.scke);
    try std.testing.expectEqual(regs.pllsta.plllock, phy.pllLock());
}

test "the line reads idle until something is attached" {
    var phy = poweredHost();
    try std.testing.expectEqual(@as(u16, 0), phy.lineState());
    phy.attached = true;
    try std.testing.expectEqual(regs.port.lnst_j, phy.lineState());
}

test "an unpowered controller reports no line state at all" {
    var phy = usbhs_phy.Phy{};
    phy.attached = true;
    try std.testing.expectEqual(@as(u16, 0), phy.lineState());
}

test "a port write needs a powered controller" {
    var phy = usbhs_phy.Phy{};
    try std.testing.expect(!phy.setPort(regs.port.usbrst));
    try std.testing.expectEqual(@as(u32, 1), phy.off);
}

test "a port write needs the host role" {
    var phy = usbhs_phy.Phy{};
    phy.setSyscfg(regs.syscfg.usbe | regs.syscfg.scke);
    try std.testing.expect(!phy.setPort(regs.port.usbrst));
    try std.testing.expectEqual(@as(u32, 1), phy.not_host);
}

test "the speed is what the reset settled on, not what was asked for" {
    var phy = poweredHost();
    phy.attached = true;
    try std.testing.expectEqual(@as(u16, 0), phy.portStatus() & regs.port.rhst_mask);
    try std.testing.expect(phy.setPort(regs.port.usbrst));
    try std.testing.expectEqual(@as(u16, 0), phy.portStatus() & regs.port.rhst_mask);
    try std.testing.expect(phy.setPort(0));
    try std.testing.expectEqual(regs.port.rhst_high, phy.portStatus() & regs.port.rhst_mask);
    try std.testing.expectEqual(@as(u32, 1), phy.resets);
}

test "a reset with nothing attached settles on no speed" {
    var phy = poweredHost();
    _ = phy.setPort(regs.port.usbrst);
    _ = phy.setPort(0);
    try std.testing.expectEqual(@as(u32, 1), phy.resets);
    try std.testing.expectEqual(usbhs_phy.Speed.none, phy.speed);
}

test "holding USBRST does not count a reset" {
    var phy = poweredHost();
    phy.attached = true;
    _ = phy.setPort(regs.port.usbrst);
    _ = phy.setPort(regs.port.usbrst | regs.port.uact);
    try std.testing.expectEqual(@as(u32, 0), phy.resets);
}

test "turning the module off forgets the speed the port found" {
    var phy = poweredHost();
    phy.attached = true;
    _ = phy.setPort(regs.port.usbrst);
    _ = phy.setPort(regs.port.uact);
    try std.testing.expectEqual(usbhs_phy.Speed.high, phy.speed);
    phy.setSyscfg(0);
    try std.testing.expectEqual(usbhs_phy.Speed.none, phy.speed);
    try std.testing.expectEqual(@as(u16, 0), phy.portStatus() & regs.port.uact);
}

test "a brought-up controller that did nothing is not quiet once it refused" {
    var phy = poweredHost();
    try std.testing.expect(phy.quiet());
    phy.refuseStatus();
    try std.testing.expect(!phy.quiet());
    try std.testing.expectEqual(@as(u32, 1), phy.refusals());
}

test "the speed field reports the encoding the driver reads" {
    try std.testing.expectEqual(@as(u16, 0), usbhs_phy.Speed.none.rhst());
    try std.testing.expectEqual(regs.port.rhst_full, usbhs_phy.Speed.full.rhst());
    try std.testing.expectEqual(regs.port.rhst_high, usbhs_phy.Speed.high.rhst());
}
