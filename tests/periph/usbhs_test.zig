//! The USBHS window: which offsets are real registers, which answer from the
//! machine, and which a store cannot reach.
const std = @import("std");
const ra8 = @import("ra8");
const regs = ra8.periph.usbhs_regs;
const usbhs = ra8.periph.usbhs;

fn at(offset: u32) u32 {
    return regs.window.base + offset;
}

fn broughtUp() usbhs.Host {
    var host = usbhs.Host{};
    host.write(at(regs.reg.syscfg), 2, regs.syscfg.usbe | regs.syscfg.scke | regs.syscfg.dcfm);
    return host;
}

test "the window is the controller's own" {
    var host = usbhs.Host{};
    const block = host.block();
    try std.testing.expectEqual(regs.window.base, block.base);
    try std.testing.expectEqual(regs.window.span, block.size);
    try std.testing.expect(block.covers(at(regs.reg.pllsta)));
    try std.testing.expect(!block.covers(regs.window.base + regs.window.span));
}

test "SYSCFG answers with the module off, or it could never be turned on" {
    var host = usbhs.Host{};
    host.write(at(regs.reg.syscfg), 2, regs.syscfg.usbe);
    try std.testing.expectEqual(@as(u32, regs.syscfg.usbe), host.read(at(regs.reg.syscfg), 2));
    try std.testing.expectEqual(@as(u32, 0), host.off);
}

test "a register read with the module off answers nothing and is counted" {
    var host = usbhs.Host{};
    try std.testing.expectEqual(@as(u32, 0), host.read(at(regs.reg.usbaddr), 2));
    host.write(at(regs.reg.usbaddr), 2, 3);
    try std.testing.expectEqual(@as(u32, 2), host.off);
}

test "an odd offset is refused rather than rounded down onto a register" {
    var host = broughtUp();
    host.write(at(regs.reg.usbaddr), 1, 0x7F);
    host.write(at(regs.reg.usbaddr) + 1, 1, 0x55);
    try std.testing.expectEqual(@as(u32, 0x7F), host.read(at(regs.reg.usbaddr), 2));
    try std.testing.expectEqual(@as(u32, 0), host.read(at(regs.reg.usbaddr) + 1, 1));
    try std.testing.expectEqual(@as(u32, 2), host.misaligned);
}

test "the PLL answers before the module does, and only once clocked" {
    var host = usbhs.Host{};
    try std.testing.expectEqual(@as(u32, 0), host.read(at(regs.reg.pllsta), 2));
    host.write(at(regs.reg.syscfg), 2, regs.syscfg.usbe | regs.syscfg.scke);
    try std.testing.expectEqual(@as(u32, regs.pllsta.plllock), host.read(at(regs.reg.pllsta), 2));
    try std.testing.expectEqual(@as(u32, 0), host.off);
}

test "the PLL status is not the driver's to set" {
    var host = broughtUp();
    host.write(at(regs.reg.pllsta), 2, 0);
    try std.testing.expectEqual(@as(u32, regs.pllsta.plllock), host.read(at(regs.reg.pllsta), 2));
    try std.testing.expectEqual(@as(u32, 1), host.read_only);
}

test "a store into SYSSTS0 does not invent an attached device" {
    var host = broughtUp();
    host.write(at(regs.reg.syssts0), 2, regs.port.lnst_j);
    try std.testing.expectEqual(@as(u32, 0), host.read(at(regs.reg.syssts0), 2));
    try std.testing.expectEqual(@as(u32, 1), host.read_only);
    host.attachDevice();
    try std.testing.expectEqual(@as(u32, regs.port.lnst_j), host.read(at(regs.reg.syssts0), 2));
}

test "RHST reports what the reset settled on" {
    var host = broughtUp();
    host.attachDevice();
    host.write(at(regs.reg.dvstctr0), 2, regs.port.usbrst);
    try std.testing.expectEqual(
        @as(u32, 0),
        host.read(at(regs.reg.dvstctr0), 2) & regs.port.rhst_mask,
    );
    host.write(at(regs.reg.dvstctr0), 2, regs.port.uact);
    try std.testing.expectEqual(
        @as(u32, regs.port.rhst_high),
        host.read(at(regs.reg.dvstctr0), 2) & regs.port.rhst_mask,
    );
    try std.testing.expectEqual(@as(u32, 1), host.phy.resets);
}

test "a port write in device role moves nothing" {
    var host = usbhs.Host{};
    host.write(at(regs.reg.syscfg), 2, regs.syscfg.usbe | regs.syscfg.scke);
    host.write(at(regs.reg.dvstctr0), 2, regs.port.usbrst);
    try std.testing.expectEqual(@as(u32, 1), host.phy.not_host);
}

test "the PIPESEL window reaches the pipe it names" {
    var host = broughtUp();
    host.write(at(regs.reg.pipesel), 2, 2);
    host.write(at(regs.reg.pipecfg), 2, regs.pipe.dir_in | 1);
    host.write(at(regs.reg.pipemaxp), 2, 512);
    try std.testing.expectEqual(@as(u32, 2), host.read(at(regs.reg.pipesel), 2));
    try std.testing.expectEqual(@as(u32, regs.pipe.dir_in | 1), host.read(at(regs.reg.pipecfg), 2));
    try std.testing.expectEqual(@as(u32, 512), host.read(at(regs.reg.pipemaxp), 2));
}

test "a config for a pipe that does not exist does not reach the control pipe" {
    var host = broughtUp();
    host.write(at(regs.reg.pipesel), 2, regs.pipe.count + 1);
    host.write(at(regs.reg.pipecfg), 2, 9);
    try std.testing.expectEqual(@as(u32, 0), host.read(at(regs.reg.pipecfg), 2));
    try std.testing.expectEqual(@as(u8, 0), host.pipes.pipes[0].endpoint);
    try std.testing.expectEqual(@as(u32, 1), host.pipes.bad_pipe);
}

test "PIPECTR slots address PIPE1 upwards" {
    var host = broughtUp();
    const slot = at(regs.reg.pipectr + regs.window.word * 2);
    host.write(slot, 2, regs.pipe.pid_buf);
    try std.testing.expectEqual(@as(u32, regs.pipe.pid_buf), host.read(slot, 2));
    try std.testing.expect(host.pipes.pipes[3].armed());
    try std.testing.expect(!host.pipes.pipes[0].armed());
}

test "an interrupt status bit clears by writing zero to it" {
    var host = broughtUp();
    host.write(at(regs.reg.brdysts), 2, 0xFFFF);
    try std.testing.expectEqual(@as(u32, 0), host.read(at(regs.reg.brdysts), 2));
    host.shadow[regs.reg.brdysts / regs.window.word] = 0x0003;
    host.write(at(regs.reg.brdysts), 2, 0x0002);
    try std.testing.expectEqual(@as(u32, 0x0002), host.read(at(regs.reg.brdysts), 2));
}

test "a register the model does not own remembers what was written" {
    var host = broughtUp();
    host.write(at(regs.reg.usbreq), 2, 0x0680);
    try std.testing.expectEqual(@as(u32, 0x0680), host.read(at(regs.reg.usbreq), 2));
}

test "the PHY page answers with the module off" {
    var host = usbhs.Host{};
    host.write(at(regs.reg.phy_page + 2), 2, 0x0001);
    try std.testing.expectEqual(@as(u32, 0x0001), host.read(at(regs.reg.phy_page + 2), 2));
    try std.testing.expectEqual(@as(u32, 0), host.off);
}

test "an untouched controller is quiet, a refusal ends that" {
    var host = usbhs.Host{};
    try std.testing.expect(host.quiet());
    _ = host.read(at(regs.reg.usbaddr) + 1, 1);
    try std.testing.expect(!host.quiet());
    try std.testing.expectEqual(@as(u32, 1), host.refusals());
}

test "the block routes through the same paths as the model" {
    var host = usbhs.Host{};
    const block = host.block();
    block.writeFn(block.context, at(regs.reg.syscfg), 2, regs.syscfg.usbe | regs.syscfg.scke);
    try std.testing.expectEqual(
        @as(u32, regs.pllsta.plllock),
        block.readFn(block.context, at(regs.reg.pllsta), 2),
    );
}
