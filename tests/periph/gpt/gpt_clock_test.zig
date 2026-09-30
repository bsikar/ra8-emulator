//! GTCR.TPCS: the clock a GPT channel counts on.
const std = @import("std");
const testing = std.testing;

const ra8 = @import("ra8");
const clk = ra8.periph.gpt_clock;
const gpt = ra8.periph.gpt;

/// A GTCR word carrying a prescaler encoding and the start bit.
fn control(encoding: u32) u32 {
    return clk.field.cst | (encoding << 23);
}

test "an empty GTCR selects the undivided clock" {
    try testing.expectEqual(clk.Source.pclkd, clk.sourceOf(0));
    try testing.expectEqual(@as(u32, 1), clk.Source.pclkd.divider());
}

test "each named encoding selects its own divider" {
    const named = [_]struct { encoding: u32, source: clk.Source, divider: u32 }{
        .{ .encoding = 0, .source = .pclkd, .divider = 1 },
        .{ .encoding = 1, .source = .pclkd_div4, .divider = 4 },
        .{ .encoding = 2, .source = .pclkd_div16, .divider = 16 },
        .{ .encoding = 3, .source = .pclkd_div64, .divider = 64 },
        .{ .encoding = 4, .source = .pclkd_div256, .divider = 256 },
        .{ .encoding = 5, .source = .pclkd_div1024, .divider = 1024 },
    };
    for (named) |case| {
        const source = clk.sourceOf(control(case.encoding));
        try testing.expectEqual(case.source, source);
        try testing.expectEqual(case.divider, source.divider());
    }
}

test "the start bit and the mode field do not disturb the prescaler" {
    const cr = control(5) | clk.field.md;
    try testing.expectEqual(clk.Source.pclkd_div1024, clk.sourceOf(cr));
}

test "an encoding nobody names counts undivided and says so" {
    const source = clk.sourceOf(control(9));
    try testing.expectEqual(@as(u32, 1), source.divider());
    try testing.expectEqualStrings("unknown count source", source.name());
}

test "every named encoding has a name that is not the unknown one" {
    const named = [_]clk.Source{
        .pclkd,       .pclkd_div4,   .pclkd_div16,
        .pclkd_div64, .pclkd_div256, .pclkd_div1024,
    };
    for (named) |source| {
        try testing.expect(!std.mem.eql(u8, "unknown count source", source.name()));
    }
}

test "a divided step is smaller, and strictly ordered by divider" {
    const per = gpt.step_per_tick;
    var previous = clk.step(per, .pclkd) + 1;
    const ordered = [_]clk.Source{
        .pclkd,       .pclkd_div4,   .pclkd_div16,
        .pclkd_div64, .pclkd_div256, .pclkd_div1024,
    };
    for (ordered) |source| {
        const step = clk.step(per, source);
        try testing.expect(step < previous);
        previous = step;
    }
}

test "a divided step stays odd, so it stays coprime to a saw period" {
    const per = gpt.step_per_tick;
    const ordered = [_]clk.Source{
        .pclkd,       .pclkd_div4,   .pclkd_div16,
        .pclkd_div64, .pclkd_div256, .pclkd_div1024,
    };
    for (ordered) |source| {
        try testing.expectEqual(@as(u32, 1), clk.step(per, source) & 1);
    }
}

test "the slowest divider still moves the counter" {
    try testing.expect(clk.step(4, .pclkd_div1024) >= 1);
    try testing.expect(clk.step(1, .pclkd_div1024) >= 1);
}

test "a channel reports the source its GTCR selects" {
    var channel = gpt.Channel{};
    channel.cr = control(2);
    try testing.expectEqual(clk.Source.pclkd_div16, channel.source());
    try testing.expect(channel.running());
}

test "a slowed channel counts behind an undivided one" {
    var fast = gpt.Channel{};
    var slow = gpt.Channel{};
    fast.cr = control(0);
    slow.cr = control(4);
    fast.period.set(.live, 0xFFFF_FFFF);
    slow.period.set(.live, 0xFFFF_FFFF);
    _ = fast.tick();
    _ = slow.tick();
    try testing.expect(slow.cnt < fast.cnt);
    try testing.expect(slow.cnt > 0);
}

test "a slowed channel overflows later than an undivided one" {
    var fast = gpt.Channel{};
    var slow = gpt.Channel{};
    fast.cr = control(0);
    slow.cr = control(3);
    fast.period.set(.live, 0x0001_0000);
    slow.period.set(.live, 0x0001_0000);
    var index: usize = 0;
    while (index < 8) : (index += 1) {
        _ = fast.tick();
        _ = slow.tick();
    }
    try testing.expect(fast.overflows > slow.overflows);
}

test "a stopped channel counts at no source at all" {
    var channel = gpt.Channel{};
    channel.cr = 0;
    channel.period.set(.live, 0xFFFF);
    try testing.expectEqual(@as(u32, 0), channel.tick());
    try testing.expectEqual(@as(u32, 0), channel.cnt);
}

test "an unnamed encoding counts at the undivided rate" {
    var named = gpt.Channel{};
    var unnamed = gpt.Channel{};
    named.cr = control(0);
    unnamed.cr = control(12);
    named.period.set(.live, 0xFFFF_FFFF);
    unnamed.period.set(.live, 0xFFFF_FFFF);
    _ = named.tick();
    _ = unnamed.tick();
    try testing.expectEqual(named.cnt, unnamed.cnt);
}

test "the prescaler survives a readback through the window" {
    var unit = gpt.Gpt.init();
    const address = gpt.win_base + gpt.off.gtcr;
    unit.write(address, 4, control(5));
    try testing.expectEqual(control(5), unit.read(address, 4));
    try testing.expectEqual(clk.Source.pclkd_div1024, unit.channels[0].source());
}

test "a byte store to GTCR's top lane changes the prescaler alone" {
    var unit = gpt.Gpt.init();
    const address = gpt.win_base + gpt.off.gtcr;
    unit.write(address, 4, clk.field.cst);
    // TPCS starts at bit 23, so the top byte lane carries its upper three
    // bits: 0x01 there is encoding 2, PCLKD/16.
    unit.write(address + 3, 1, 0x01);
    try testing.expectEqual(clk.Source.pclkd_div16, unit.channels[0].source());
    try testing.expect(unit.channels[0].running());
}

test "two channels of one unit can count at different rates" {
    var unit = gpt.Gpt.init();
    unit.write(gpt.win_base + gpt.off.gtcr, 4, control(0));
    unit.write(gpt.win_base + gpt.stride + gpt.off.gtcr, 4, control(5));
    unit.write(gpt.win_base + gpt.off.gtpr, 4, 0xFFFF_FFFF);
    unit.write(gpt.win_base + gpt.stride + gpt.off.gtpr, 4, 0xFFFF_FFFF);
    unit.tick();
    try testing.expect(unit.channels[1].cnt < unit.channels[0].cnt);
}
