//! Covers src/periph/agt.zig: the interval timer, and the four places dev
//! lets a misbehaving image pass.
const std = @import("std");
const ra8 = @import("ra8");

const agt = ra8.periph.agt;

const ch0 = agt.win_base;
const ch1 = agt.win_base + agt.stride;

fn armed(unit: *agt.Agt, base: u32, period: u16) void {
    unit.write(base + agt.off.cnt, 2, period);
    unit.write(base + agt.off.cr, 1, agt.control.tstart);
}

test "a reset channel is stopped, empty and silent" {
    var unit = agt.Agt.init();
    try std.testing.expectEqual(@as(u32, 0), unit.read(ch0 + agt.off.cr, 1));
    try std.testing.expectEqual(@as(u32, 0), unit.read(ch0 + agt.off.cnt, 2));
    try std.testing.expect(unit.quiet());
}

test "a counter write seeds both the count and the reload" {
    var unit = agt.Agt.init();
    unit.write(ch0 + agt.off.cnt, 2, 0x4000);
    try std.testing.expectEqual(@as(u32, 0x4000), unit.read(ch0 + agt.off.cnt, 2));
    try std.testing.expectEqual(@as(u16, 0x4000), unit.channels[0].reload);
}

test "TSTART raises the read-only count-status flag firmware polls" {
    var unit = agt.Agt.init();
    armed(&unit, ch0, 0x4000);
    const cr = unit.read(ch0 + agt.off.cr, 1);
    try std.testing.expect(cr & agt.control.tstart != 0);
    try std.testing.expect(cr & agt.control.tcstf != 0);
}

test "TSTOP beats TSTART in the same write, which dev discards" {
    var unit = agt.Agt.init();
    armed(&unit, ch0, 0x4000);
    unit.write(ch0 + agt.off.cr, 1, agt.control.tstart | agt.control.tstop);
    try std.testing.expect(!unit.channels[0].running());
    try std.testing.expectEqual(@as(u32, 0), unit.read(ch0 + agt.off.cr, 1) & agt.control.tcstf);
    try std.testing.expectEqual(@as(u32, 1), unit.channels[0].forced_stops);
}

test "a stopped channel holds its count" {
    var unit = agt.Agt.init();
    unit.write(ch0 + agt.off.cnt, 2, 0x4000);
    unit.tick();
    try std.testing.expectEqual(@as(u32, 0x4000), unit.read(ch0 + agt.off.cnt, 2));
    try std.testing.expectEqual(@as(u32, 0), unit.channels[0].underflows);
}

test "a running channel counts down by one step per boundary" {
    var unit = agt.Agt.init();
    armed(&unit, ch0, 0x4000);
    unit.tick();
    try std.testing.expectEqual(
        @as(u32, 0x4000 - agt.step_per_tick),
        unit.read(ch0 + agt.off.cnt, 2),
    );
}

test "the count underflows, reloads and latches TUNDF" {
    var unit = agt.Agt.init();
    armed(&unit, ch0, 0x0400);
    unit.tick();
    try std.testing.expectEqual(@as(u32, 1), unit.channels[0].underflows);
    try std.testing.expect(unit.read(ch0 + agt.off.cr, 1) & agt.control.tundf != 0);
    try std.testing.expect(unit.channels[0].counter <= 0x0400);
}

test "the underflow raises the AGT0 combined event once" {
    var unit = agt.Agt.init();
    armed(&unit, ch0, 0x0400);
    unit.tick();
    const due = unit.dueEvents();
    try std.testing.expectEqual(@as(usize, 1), due.len);
    try std.testing.expectEqual(agt.event.agt0, due.get(0));
    try std.testing.expectEqual(@as(usize, 0), unit.dueEvents().len);
}

test "a channel other than zero counts without raising an event" {
    var unit = agt.Agt.init();
    armed(&unit, ch1, 0x0400);
    unit.tick();
    try std.testing.expectEqual(@as(u32, 1), unit.channels[1].underflows);
    try std.testing.expectEqual(@as(usize, 0), unit.dueEvents().len);
}

test "a status flag is cleared by writing its bit zero, not one" {
    var unit = agt.Agt.init();
    armed(&unit, ch0, 0x0400);
    unit.tick();
    unit.write(ch0 + agt.off.cr, 1, agt.control.tstart | agt.control.tundf);
    try std.testing.expect(unit.read(ch0 + agt.off.cr, 1) & agt.control.tundf != 0);
    unit.write(ch0 + agt.off.cr, 1, agt.control.tstart);
    try std.testing.expectEqual(@as(u32, 0), unit.read(ch0 + agt.off.cr, 1) & agt.control.tundf);
}

test "a count passing the compare value sets TCMAF, which dev never raises" {
    var unit = agt.Agt.init();
    unit.write(ch0 + agt.off.cma, 2, 0x3800);
    armed(&unit, ch0, 0x4000);
    unit.tick();
    try std.testing.expectEqual(@as(u32, 1), unit.channels[0].matches_a);
    try std.testing.expect(unit.read(ch0 + agt.off.cr, 1) & agt.control.tcmaf != 0);
}

test "a compare value the count has not reached does not match" {
    var unit = agt.Agt.init();
    unit.write(ch0 + agt.off.cmb, 2, 0x0100);
    armed(&unit, ch0, 0x4000);
    unit.tick();
    try std.testing.expectEqual(@as(u32, 0), unit.channels[0].matches_b);
}

test "a compare left at zero is unarmed and never matches" {
    var unit = agt.Agt.init();
    armed(&unit, ch0, 0x0400);
    unit.tick();
    try std.testing.expectEqual(@as(u32, 0), unit.channels[0].matches_a);
    try std.testing.expectEqual(@as(u32, 0), unit.channels[0].matches_b);
}

test "a counter write with the count running is refused" {
    var unit = agt.Agt.init();
    armed(&unit, ch0, 0x4000);
    unit.write(ch0 + agt.off.cnt, 2, 0x0010);
    try std.testing.expectEqual(@as(u32, 0x4000), unit.read(ch0 + agt.off.cnt, 2));
    try std.testing.expectEqual(@as(u32, 2), unit.channels[0].refused_running);
}

test "an uninterpreted register keeps what was written" {
    var unit = agt.Agt.init();
    unit.write(ch0 + agt.off.mr1, 1, 0x5A);
    try std.testing.expectEqual(@as(u32, 0x5A), unit.read(ch0 + agt.off.mr1, 1));
    unit.write(ch0 + 0x0C, 1, 0xC3);
    try std.testing.expectEqual(@as(u32, 0xC3), unit.read(ch0 + 0x0C, 1));
}

test "a byte store lands on its own lane of the counter" {
    var unit = agt.Agt.init();
    unit.write(ch0 + agt.off.cnt, 2, 0x1234);
    unit.write(ch0 + agt.off.cnt + 1, 1, 0xAB);
    try std.testing.expectEqual(@as(u32, 0xAB34), unit.read(ch0 + agt.off.cnt, 2));
}

test "the crossing test covers a chunk that wrapped through the reload" {
    try std.testing.expect(agt.crossed(0x0100, 0x3F00, true, 0x4000, 0x0080));
    try std.testing.expect(agt.crossed(0x0100, 0x3F00, true, 0x4000, 0x3F80));
    try std.testing.expect(!agt.crossed(0x0100, 0x3F00, true, 0x4000, 0x3E00));
}

test "a block answers on its own window and nowhere else" {
    var unit = agt.Agt.init();
    const block = unit.block();
    try std.testing.expect(block.covers(agt.win_base));
    try std.testing.expect(block.covers(agt.win_base + agt.win_span - 1));
    try std.testing.expect(!block.covers(agt.win_base + agt.win_span));
}
