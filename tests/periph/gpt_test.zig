//! Covers src/periph/gpt.zig: the saw counter the PWM images sample, and the
//! three places dev's wrap arithmetic lets a bad run look clean.
const std = @import("std");
const ra8 = @import("ra8");

const gpt = ra8.periph.gpt;

const ch0 = gpt.win_base;
const ch1 = gpt.win_base + gpt.stride;

fn started(unit: *gpt.Gpt, base: u32, period: u32) void {
    unit.write(base + gpt.off.gtpr, 4, period);
    // CSTRTn is channel-indexed, so starting this channel means naming its
    // own bit, whichever window the store goes through.
    const index = (base - gpt.win_base) / gpt.stride;
    unit.write(base + gpt.off.gtstr, 4, @as(u32, 1) << @intCast(index));
}

test "a reset channel is stopped, empty and silent" {
    var unit = gpt.Gpt.init();
    try std.testing.expectEqual(@as(u32, 0), unit.read(ch0 + gpt.off.gtcnt, 4));
    try std.testing.expectEqual(@as(u32, 0), unit.read(ch0 + gpt.off.gtcr, 4));
    try std.testing.expect(unit.quiet());
}

test "GTSTR starts the count and GTSTP stops it" {
    var unit = gpt.Gpt.init();
    started(&unit, ch0, 0xFFFF);
    try std.testing.expect(unit.read(ch0 + gpt.off.gtcr, 4) & gpt.control.cst != 0);
    unit.write(ch0 + gpt.off.gtstp, 4, 1);
    try std.testing.expectEqual(@as(u32, 0), unit.read(ch0 + gpt.off.gtcr, 4) & gpt.control.cst);
}

test "a stopped channel holds its count" {
    var unit = gpt.Gpt.init();
    unit.write(ch0 + gpt.off.gtpr, 4, 0xFFFF);
    unit.tick();
    try std.testing.expectEqual(@as(u32, 0), unit.read(ch0 + gpt.off.gtcnt, 4));
}

test "a running channel advances by one odd step per boundary" {
    var unit = gpt.Gpt.init();
    started(&unit, ch0, 0xFFFF);
    unit.tick();
    try std.testing.expectEqual(gpt.step_per_tick, unit.read(ch0 + gpt.off.gtcnt, 4));
    unit.tick();
    try std.testing.expectEqual(2 * gpt.step_per_tick, unit.read(ch0 + gpt.off.gtcnt, 4));
}

test "GTCLR clears the count without stopping it" {
    var unit = gpt.Gpt.init();
    started(&unit, ch0, 0xFFFF);
    unit.tick();
    unit.write(ch0 + gpt.off.gtclr, 4, 1);
    try std.testing.expectEqual(@as(u32, 0), unit.read(ch0 + gpt.off.gtcnt, 4));
    try std.testing.expect(unit.channels[0].running());
}

test "a wrap past the period latches TCFPO and raises the GPT0 event" {
    var unit = gpt.Gpt.init();
    started(&unit, ch0, 0x8000);
    // Two boundaries: one step of 0x4001 is still inside an 0x8000 period.
    unit.tick();
    unit.tick();
    try std.testing.expectEqual(@as(u32, 1), unit.channels[0].overflows);
    try std.testing.expect(unit.read(ch0 + gpt.off.gtst, 4) & gpt.status.tcfpo != 0);
    const due = unit.dueEvents();
    try std.testing.expectEqual(@as(usize, 1), due.len);
    try std.testing.expectEqual(gpt.event.gpt0_overflow, due.get(0));
    try std.testing.expectEqual(@as(usize, 0), unit.dueEvents().len);
}

test "the full 32-bit period still overflows, where dev's sum wrapped first" {
    var unit = gpt.Gpt.init();
    started(&unit, ch0, 0xFFFF_FFFF);
    unit.write(ch0 + gpt.off.gtcnt, 4, 0xFFFF_FFFF - 2);
    unit.tick();
    try std.testing.expectEqual(@as(u32, 1), unit.channels[0].overflows);
    try std.testing.expect(unit.read(ch0 + gpt.off.gtcnt, 4) < gpt.step_per_tick);
}

test "a period shorter than one step keeps the count inside it" {
    var unit = gpt.Gpt.init();
    started(&unit, ch0, 0x0100);
    unit.tick();
    const count = unit.read(ch0 + gpt.off.gtcnt, 4);
    try std.testing.expect(count <= 0x0100);
    try std.testing.expectEqual(
        @as(u32, (gpt.step_per_tick) / 0x0101),
        unit.channels[0].overflows,
    );
}

test "several wraps in one boundary are one interrupt" {
    var unit = gpt.Gpt.init();
    started(&unit, ch0, 0x0100);
    unit.tick();
    try std.testing.expect(unit.channels[0].overflows > 1);
    try std.testing.expectEqual(@as(usize, 1), unit.dueEvents().len);
}

test "a channel other than zero counts without raising an event" {
    var unit = gpt.Gpt.init();
    started(&unit, ch1, 0x8000);
    unit.tick();
    unit.tick();
    try std.testing.expectEqual(@as(u32, 1), unit.channels[1].overflows);
    try std.testing.expectEqual(@as(usize, 0), unit.dueEvents().len);
}

test "GTPR left at zero counts to the 16-bit wrap" {
    var unit = gpt.Gpt.init();
    unit.write(ch0 + gpt.off.gtstr, 4, 1);
    try std.testing.expectEqual(gpt.default_period, unit.channels[0].periodOrDefault());
    unit.tick();
    try std.testing.expectEqual(gpt.step_per_tick, unit.read(ch0 + gpt.off.gtcnt, 4));
}

test "a status store can only clear a flag, never raise one" {
    var unit = gpt.Gpt.init();
    started(&unit, ch0, 0x8000);
    unit.tick();
    unit.tick();
    unit.write(ch0 + gpt.off.gtst, 4, gpt.status.tcfa);
    try std.testing.expectEqual(@as(u32, 0), unit.read(ch0 + gpt.off.gtst, 4));
    unit.write(ch0 + gpt.off.gtst, 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), unit.read(ch0 + gpt.off.gtst, 4));
}

test "an uninterpreted register keeps what was written" {
    var unit = gpt.Gpt.init();
    unit.write(ch0 + 0x1C, 4, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), unit.read(ch0 + 0x1C, 4));
}

test "a halfword store lands on its own half of the period" {
    var unit = gpt.Gpt.init();
    unit.write(ch0 + gpt.off.gtpr, 4, 0x1234_5678);
    unit.write(ch0 + gpt.off.gtpr + 2, 2, 0xABCD);
    try std.testing.expectEqual(@as(u32, 0xABCD_5678), unit.read(ch0 + gpt.off.gtpr, 4));
}

test "a byte store one in from GTSTR names the upper channels" {
    var unit = gpt.Gpt.init();
    unit.write(ch0 + gpt.off.gtstr + 1, 1, 0xFF);
    // Lane 1 carries bits 8..15, so channel 0 is untouched and 8..13 start.
    try std.testing.expect(!unit.channels[0].running());
    try std.testing.expect(unit.channels[8].running());
    try std.testing.expect(unit.channels[13].running());
    try std.testing.expectEqual(@as(u32, 6), unit.sync.acted);
    // Bits 14 and 15 name channels this bank does not carry.
    try std.testing.expectEqual(@as(u32, 2), unit.sync.absent);
}

test "one store starts three channels on the same edge" {
    var unit = gpt.Gpt.init();
    // What ra8_gpt_three_phase_open does: one masked GTSTR store through the
    // U channel's window for U, V and W.
    unit.write(ch0 + gpt.off.gtstr, 4, 0b111);
    try std.testing.expect(unit.channels[0].running());
    try std.testing.expect(unit.channels[1].running());
    try std.testing.expect(unit.channels[2].running());
    try std.testing.expectEqual(@as(u32, 1), unit.sync.together);
    // And the close path stops the same three with one GTSTP store.
    unit.write(ch0 + gpt.off.gtstp, 4, 0b111);
    try std.testing.expect(!unit.channels[0].running());
    try std.testing.expect(!unit.channels[1].running());
    try std.testing.expect(!unit.channels[2].running());
    try std.testing.expectEqual(@as(u32, 2), unit.sync.together);
}

test "a block answers on its own window and nowhere else" {
    var unit = gpt.Gpt.init();
    const block = unit.block();
    try std.testing.expect(block.covers(gpt.win_base));
    try std.testing.expect(block.covers(gpt.win_base + gpt.win_span - 1));
    try std.testing.expect(!block.covers(gpt.win_base + gpt.win_span));
}
