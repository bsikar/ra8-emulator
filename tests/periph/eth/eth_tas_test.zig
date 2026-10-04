//! TAS gate-list RAM and cycle register behavior.
const std = @import("std");
const ra8 = @import("ra8");
const engine = ra8.core.engine;
const eth = ra8.periph.eth;
const regs = ra8.periph.eth_regs;
const net = ra8.board.net;
const periph = ra8.periph.registry;
const pdctr = ra8.periph.pdctr;
const prcr = ra8.periph.prcr;

const base = regs.cluster.etha0;

fn entry(unit: *eth.tas.Tas, address: u32, value: u32) void {
    unit.write(base + eth.tas.reg.learn_address, 4, address);
    unit.write(base + eth.tas.reg.learn_data, 4, value);
}

test "TAS gate entries learn and read back from their addressed RAM slots" {
    var unit = eth.tas.Tas.init(base);
    const open = eth.tas.reg.gate_state | 0x0123_4567;
    const closed: u32 = 0x0765_4321;

    unit.write(base + eth.tas.reg.ram_init, 4, eth.tas.reg.ram_init_request);
    try std.testing.expectEqual(eth.tas.reg.ram_ready, unit.read(base + eth.tas.reg.ram_init, 4));
    entry(&unit, 7, open);
    entry(&unit, 8, closed | eth.tas.reg.busy);
    try std.testing.expectEqual(@as(u32, 0), unit.read(base + eth.tas.reg.learn_status, 4));

    unit.write(base + eth.tas.reg.read_address, 4, 7);
    try std.testing.expectEqual(open, unit.read(base + eth.tas.reg.read_result, 4));
    unit.write(base + eth.tas.reg.read_address, 4, 8);
    try std.testing.expectEqual(closed, unit.read(base + eth.tas.reg.read_result, 4));
    try std.testing.expectEqual(@as(u32, 2), unit.learns);
    try std.testing.expectEqual(@as(u32, 2), unit.reads);
}

test "TAS cycle time reads through configuration and active monitoring" {
    var unit = eth.tas.Tas.init(base);
    const cycle: u32 = 250_000;
    unit.write(base + eth.tas.reg.cycle_time, 4, cycle);
    unit.write(base + eth.tas.reg.config, 4, eth.tas.reg.tas_enable | 0x6);

    try std.testing.expectEqual(eth.tas.reg.tas_enable, unit.read(base + eth.tas.reg.config, 4));
    try std.testing.expectEqual(cycle, unit.read(base + eth.tas.reg.cycle_time, 4));
    try std.testing.expectEqual(cycle, unit.read(base + eth.tas.reg.cycle_monitor, 4));
    unit.write(base + eth.tas.reg.config, 4, 0);
    try std.testing.expectEqual(@as(u32, 0), unit.read(base + eth.tas.reg.cycle_monitor, 4));
}

test "TAS register window is connected to the powered board bus" {
    var bus = periph.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var cluster = net.Rswitch{};
    var core = try engine.Engine.open();
    defer core.close();
    var guard = prcr.Prcr.init();
    guard.write(prcr.win_base, 2, prcr.unlockWord(pdctr.guard));
    var domain = pdctr.Pdctr.init(&guard, .eswm);
    domain.write(pdctr.Domain.eswm.base(), 1, 0);
    try cluster.attach(&bus, .{ .engine = core }, &domain);

    const expected = eth.tas.reg.gate_state | 0x0055_aa55;
    bus.write(base + eth.tas.reg.ram_init, 4, eth.tas.reg.ram_init_request);
    bus.write(base + eth.tas.reg.learn_address, 4, 3);
    bus.write(base + eth.tas.reg.learn_data, 4, expected);
    bus.write(base + eth.tas.reg.read_address, 4, 3);
    try std.testing.expectEqual(expected, bus.read(base + eth.tas.reg.read_result, 4));
    try std.testing.expectEqual(@as(u32, 0), bus.read(base + eth.tas.reg.learn_status, 4));
}
