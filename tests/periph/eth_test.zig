//! One R-Switch port on the bus: the mode registers a driver polls and the
//! MDIO window it brings the link up through.
const std = @import("std");
const ra8 = @import("ra8");
const engine = ra8.core.engine;
const periph = ra8.periph.registry;
const regs = ra8.periph.eth_regs;
const eth = ra8.periph.eth;
const eth_phy = ra8.periph.eth_phy;
const net = ra8.board.net;

fn portZero() eth.Port {
    return eth.Port.init(regs.cluster.etha0, regs.cluster.rmac0);
}

fn mdio(index: u32, op: regs.Op, data: u16) u32 {
    return regs.rmac.psme |
        (eth_phy.address << regs.rmac.pda_shift) |
        (index << regs.rmac.pra_shift) |
        (@as(u32, @intFromEnum(op)) << regs.rmac.pop_shift) |
        (@as(u32, data) << regs.rmac.prd_shift);
}

test "EAMS reports the mode the port reached" {
    var port = portZero();
    for ([_]u32{ 1, 2 }) |code| port.ethaWrite(regs.cluster.etha0 + regs.etha.eamc, 4, code);
    try std.testing.expectEqual(@as(u32, 2), port.ethaRead(regs.cluster.etha0 + regs.etha.eams, 4));
}

test "EAMS is the port's to report, so a store there moves nothing" {
    var port = portZero();
    port.ethaWrite(regs.cluster.etha0 + regs.etha.eams, 4, 3);
    try std.testing.expectEqual(@as(u32, 0), port.ethaRead(regs.cluster.etha0 + regs.etha.eams, 4));
    try std.testing.expectEqual(@as(u32, 0), port.mode.commands);
}

test "a mode command that skips a rung leaves the status where it was" {
    var port = portZero();
    port.ethaWrite(regs.cluster.etha0 + regs.etha.eamc, 4, 3);
    try std.testing.expectEqual(@as(u32, 0), port.ethaRead(regs.cluster.etha0 + regs.etha.eams, 4));
    try std.testing.expectEqual(@as(u32, 1), port.mode.refused);
}

test "an MPSM read answers in the data field and clears PSME" {
    var port = portZero();
    port.rmacWrite(regs.cluster.rmac0, 4, mdio(eth_phy.reg.bmsr, .read, 0));
    const out = port.rmacRead(regs.cluster.rmac0, 4);
    try std.testing.expectEqual(eth_phy.seed.bmsr, regs.dataOf(out));
    try std.testing.expectEqual(@as(u32, 0), out & regs.rmac.psme);
}

test "MPSM without PSME is a register, not a frame" {
    var port = portZero();
    port.rmacWrite(regs.cluster.rmac0, 4, 0x1234_0000);
    try std.testing.expectEqual(@as(u32, 0x1234_0000), port.rmacRead(regs.cluster.rmac0, 4));
    try std.testing.expect(port.phy.quiet());
}

test "the two ports keep their own PHY" {
    var one = portZero();
    var two = eth.Port.init(regs.cluster.etha1, regs.cluster.rmac1);
    one.rmacWrite(regs.cluster.rmac0, 4, mdio(eth_phy.reg.anar, .write, 0x0041));
    two.rmacWrite(regs.cluster.rmac1, 4, mdio(eth_phy.reg.anar, .read, 0));
    try std.testing.expectEqual(eth_phy.seed.anar, regs.dataOf(two.rmacRead(regs.cluster.rmac1, 4)));
}

test "a frame built in two halfword stores goes out whole" {
    var port = portZero();
    const at = regs.cluster.rmac0;
    const frame = mdio(eth_phy.reg.anar, .write, 0x0041);
    // Data half first, control half second: the order a driver that lays the
    // value down before arming the frame would use.
    port.rmacWrite(at + 2, 2, frame >> 16);
    port.rmacWrite(at, 2, frame & 0xFFFF);
    try std.testing.expectEqual(@as(u32, 1), port.phy.writes);
    try std.testing.expectEqual(@as(u16, 0x0041), port.phy.value(eth_phy.reg.anar));
}

test "the control half of MPSM leaves the data half alone" {
    var port = portZero();
    const at = regs.cluster.rmac0;
    port.rmacWrite(at + 2, 2, 0xBEEF);
    port.rmacWrite(at, 2, eth_phy.address << regs.rmac.pda_shift);
    try std.testing.expectEqual(@as(u16, 0xBEEF), regs.dataOf(port.rmacRead(at, 4)));
}

test "a halfword read of MPSM answers the half it names" {
    var port = portZero();
    port.rmacWrite(regs.cluster.rmac0, 4, mdio(eth_phy.reg.bmsr, .read, 0));
    const high = port.rmacRead(regs.cluster.rmac0 + 2, 2);
    try std.testing.expectEqual(@as(u32, eth_phy.seed.bmsr), high);
}

test "a store above OPC is not a mode command" {
    var port = portZero();
    port.ethaWrite(regs.cluster.etha0 + regs.etha.eamc + 2, 2, 0xFFFF);
    try std.testing.expectEqual(@as(u32, 0), port.mode.commands);
}

test "a byte store at EAMC commands the port" {
    var port = portZero();
    port.ethaWrite(regs.cluster.etha0 + regs.etha.eamc, 1, 1);
    try std.testing.expectEqual(@as(u32, 1), port.ethaRead(regs.cluster.etha0 + regs.etha.eams, 1));
}

test "a port nothing touched is quiet" {
    const port = portZero();
    try std.testing.expect(port.quiet());
}

test "the cluster answers on the bus at every window it claims" {
    var bus = periph.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var cluster = net.Rswitch{};
    var core = try engine.Engine.open();
    defer core.close();
    try cluster.attach(&bus, core);
    bus.write(regs.cluster.etha0 + regs.etha.eamc, 4, 1);
    try std.testing.expectEqual(@as(u32, 1), bus.read(regs.cluster.etha0 + regs.etha.eams, 4));
    bus.write(regs.cluster.gwca0 + regs.gwca.gwmc, 4, 1);
    try std.testing.expectEqual(@as(u32, 1), bus.read(regs.cluster.gwca0 + regs.gwca.gwms, 4));
}

test "the cluster's config registers still read back off the bus" {
    var bus = periph.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var cluster = net.Rswitch{};
    var core = try engine.Engine.open();
    defer core.close();
    try cluster.attach(&bus, core);
    // An ETHA queue register nothing models: the bus remembers it, which is
    // all the C tree's flat shadow did for this address.
    bus.write(regs.cluster.etha0 + 0x0018, 4, 0xABCD);
    try std.testing.expectEqual(@as(u32, 0xABCD), bus.read(regs.cluster.etha0 + 0x0018, 4));
}

test "a cluster nothing touched is quiet" {
    const cluster = net.Rswitch{};
    try std.testing.expect(cluster.quiet());
}
