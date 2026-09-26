//! Covers src/periph/elc.zig: the event link controller.
const std = @import("std");
const ra8 = @import("ra8");

const elc = ra8.periph.elc;

/// A generator sequence the hardware accepts: unlock, arm, fire.
const step = struct {
    const unlock: u32 = 0x00;
    const arm: u32 = 0x40;
    const trigger: u32 = 0x41;
};

fn fire(unit: *elc.Elc, index: usize) void {
    const address = elc.generatorAddress(index);
    unit.write(address, 1, step.unlock);
    unit.write(address, 1, step.arm);
    unit.write(address, 1, step.trigger);
}

fn enable(unit: *elc.Elc) void {
    unit.write(elc.win_base + elc.off.elcr, 1, elc.field.elcon);
}

test "the block is off at reset and nothing is linked" {
    var unit = elc.Elc.init();
    try std.testing.expect(!unit.enabled());
    try std.testing.expectEqual(@as(u32, 0), unit.linkCount());
    try std.testing.expect(unit.quiet());
}

test "ELCR.ELCON switches the block on" {
    var unit = elc.Elc.init();
    enable(&unit);
    try std.testing.expect(unit.enabled());
    try std.testing.expectEqual(@as(u32, elc.field.elcon), unit.read(elc.win_base, 1));
}

test "the three-step sequence generates a software event" {
    var unit = elc.Elc.init();
    enable(&unit);
    fire(&unit, 0);
    try std.testing.expectEqual(@as(u32, 1), unit.generated);
    const due = unit.takeEvents();
    try std.testing.expectEqual(@as(usize, 1), due.len);
    try std.testing.expectEqual(elc.softwareEvent(0), due.get(0));
}

test "each generator produces its own event number" {
    var unit = elc.Elc.init();
    enable(&unit);
    for (0..elc.generators) |index| fire(&unit, index);
    const due = unit.takeEvents();
    try std.testing.expectEqual(elc.generators, due.len);
    for (0..elc.generators) |index| {
        try std.testing.expectEqual(elc.softwareEvent(index), due.get(index));
    }
    try std.testing.expectEqual(@as(u16, 0x0CC), elc.softwareEvent(0));
    try std.testing.expectEqual(@as(u16, 0x0CF), elc.softwareEvent(3));
}

test "a bare trigger write with no arming step generates nothing" {
    var unit = elc.Elc.init();
    enable(&unit);
    unit.write(elc.generatorAddress(0), 1, step.trigger);
    try std.testing.expectEqual(@as(u32, 0), unit.generated);
    try std.testing.expectEqual(@as(u32, 1), unit.unarmed);
    try std.testing.expectEqual(@as(usize, 0), unit.takeEvents().len);
}

test "a write that sets WI is discarded whole" {
    var unit = elc.Elc.init();
    enable(&unit);
    unit.write(elc.generatorAddress(0), 1, elc.field.wi | elc.field.we | elc.field.seg);
    try std.testing.expectEqual(@as(u32, 1), unit.inhibited);
    try std.testing.expectEqual(@as(u32, 0), unit.generated);
    try std.testing.expectEqual(@as(u32, 0), unit.unarmed);
}

test "a generator disarms after firing, so a second event needs its own sequence" {
    var unit = elc.Elc.init();
    enable(&unit);
    fire(&unit, 0);
    unit.write(elc.generatorAddress(0), 1, step.trigger);
    try std.testing.expectEqual(@as(u32, 1), unit.generated);
    try std.testing.expectEqual(@as(u32, 1), unit.unarmed);
}

test "the unlock step disarms a generator left armed" {
    var unit = elc.Elc.init();
    enable(&unit);
    const address = elc.generatorAddress(1);
    unit.write(address, 1, step.unlock);
    unit.write(address, 1, step.arm);
    unit.write(address, 1, step.unlock);
    unit.write(address, 1, step.trigger);
    try std.testing.expectEqual(@as(u32, 0), unit.generated);
    try std.testing.expectEqual(@as(u32, 1), unit.unarmed);
}

test "WI reads back set and WE follows the arming step" {
    var unit = elc.Elc.init();
    const address = elc.generatorAddress(2);
    try std.testing.expectEqual(@as(u32, elc.field.wi), unit.read(address, 1));
    unit.write(address, 1, step.unlock);
    unit.write(address, 1, step.arm);
    try std.testing.expectEqual(@as(u32, elc.field.wi | elc.field.we), unit.read(address, 1));
}

test "SEG never reads back as one" {
    var unit = elc.Elc.init();
    enable(&unit);
    fire(&unit, 0);
    try std.testing.expectEqual(@as(u32, 0), unit.read(elc.generatorAddress(0), 1) & elc.field.seg);
}

test "a full sequence with ELCON clear generates nothing and says so" {
    var unit = elc.Elc.init();
    fire(&unit, 0);
    try std.testing.expectEqual(@as(u32, 0), unit.generated);
    try std.testing.expectEqual(@as(u32, 1), unit.disabled);
    try std.testing.expectEqual(@as(usize, 0), unit.takeEvents().len);
}

test "ELSR links a peripheral slot to a source event" {
    var unit = elc.Elc.init();
    unit.write(elc.linkAddress(7), 2, elc.softwareEvent(0));
    try std.testing.expectEqual(@as(u32, 1), unit.linkCount());
    try std.testing.expectEqual(@as(?usize, 7), unit.target(elc.softwareEvent(0)));
    try std.testing.expectEqual(@as(u32, elc.softwareEvent(0)), unit.read(elc.linkAddress(7), 2));
}

test "ELS zero is no link, so event zero never matches" {
    var unit = elc.Elc.init();
    try std.testing.expectEqual(@as(?usize, null), unit.target(0));
    unit.write(elc.linkAddress(3), 2, 0);
    try std.testing.expectEqual(@as(u32, 0), unit.linkCount());
}

test "an event with a link that nothing models is counted as unconsumed" {
    var unit = elc.Elc.init();
    enable(&unit);
    unit.write(elc.linkAddress(12), 2, elc.softwareEvent(1));
    fire(&unit, 1);
    try std.testing.expectEqual(@as(u32, 1), unit.generated);
    try std.testing.expectEqual(@as(u32, 1), unit.unconsumed);
}

test "an event with no link generates but is not counted as unconsumed" {
    var unit = elc.Elc.init();
    enable(&unit);
    fire(&unit, 2);
    try std.testing.expectEqual(@as(u32, 1), unit.generated);
    try std.testing.expectEqual(@as(u32, 0), unit.unconsumed);
}

test "draining the pending set empties it" {
    var unit = elc.Elc.init();
    enable(&unit);
    fire(&unit, 0);
    try std.testing.expectEqual(@as(usize, 1), unit.takeEvents().len);
    try std.testing.expectEqual(@as(usize, 0), unit.takeEvents().len);
}

test "attribution registers are stored and read back" {
    var unit = elc.Elc.init();
    unit.write(elc.win_base + elc.off.elcsara, 4, 0xDEAD_BEEF);
    unit.write(elc.win_base + elc.off.elcpara + 8, 4, 0x1234_5678);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), unit.read(elc.win_base + elc.off.elcsara, 4));
    try std.testing.expectEqual(@as(u32, 0x1234_5678), unit.read(elc.win_base + elc.off.elcpara + 8, 4));
}

test "the window covers every register and the block claims it once" {
    var unit = elc.Elc.init();
    const block = unit.block();
    try std.testing.expect(block.covers(elc.win_base));
    try std.testing.expect(block.covers(elc.linkAddress(elc.links - 1)));
    try std.testing.expect(block.covers(elc.win_base + elc.off.elcpara + 8));
    try std.testing.expect(!block.covers(elc.win_base + elc.win_span));
}

test "the block answers through the bus at its own window" {
    var bus = ra8.periph.registry.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var unit = elc.Elc.init();
    try bus.add(unit.block());
    bus.write(elc.win_base, 1, elc.field.elcon);
    try std.testing.expect(unit.enabled());
    bus.write(elc.generatorAddress(0), 1, step.unlock);
    bus.write(elc.generatorAddress(0), 1, step.arm);
    bus.write(elc.generatorAddress(0), 1, step.trigger);
    try std.testing.expectEqual(@as(u32, 1), unit.generated);
}

test "a touched block is not quiet" {
    var unit = elc.Elc.init();
    try std.testing.expect(unit.quiet());
    unit.write(elc.linkAddress(0), 2, elc.softwareEvent(3));
    try std.testing.expect(!unit.quiet());
}
