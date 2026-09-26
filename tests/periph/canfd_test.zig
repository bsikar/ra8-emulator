//! tests/periph/canfd_test.zig covers src/periph/canfd.zig: the two CAN-FD
//! controllers, their mode machines, and the internal loopback.
const std = @import("std");
const ra8 = @import("ra8");
const canfd = ra8.periph.canfd;
const fifo = ra8.periph.canfd_fifo;

const unit0 = canfd.unit0_base;
const unit1 = canfd.unit1_base;

/// Bring both mode machines of one unit into operation, the way the driver
/// does: global first, then the channel.
fn start(model: *canfd.Canfd, base: u32) void {
    model.write(base + canfd.off_gctr, 4, 0);
    model.write(base + canfd.off_cnctr, 4, 0);
}

/// Load TX message buffer 0 with an identifier, a length code and one data
/// word, then assert the transmit request.
fn send(model: *canfd.Canfd, base: u32, id: u32, dlc: u32, payload: u32) void {
    model.write(base + canfd.off_tm0, 4, id);
    model.write(base + canfd.off_tm0 + 4, 4, dlc << fifo.ptr.dlc_shift);
    model.write(base + canfd.off_tm0 + 12, 4, payload);
    model.write(base + canfd.off_tmc0, 4, canfd.field.tmtr);
}

/// Program acceptance-filter slot `slot` with an identifier and its mask.
fn filter(model: *canfd.Canfd, base: u32, slot: u32, id: u32, mask: u32) void {
    const entry = canfd.off_afl + slot * canfd.afl.stride;
    model.write(base + entry, 4, id);
    model.write(base + entry + 4, 4, mask);
}

test "both machines power up in reset, and the FIFO powers up empty" {
    var model = canfd.Canfd.init();
    try std.testing.expectEqual(canfd.field.grststs, model.read(unit0 + canfd.off_gsts, 4));
    try std.testing.expectEqual(canfd.field.crststs, model.read(unit0 + canfd.off_cnsts, 4));
    try std.testing.expectEqual(canfd.field.rfemp, model.read(unit0 + canfd.off_rfsts0, 4));
    // GRAMINIT is clear from power-up: there is no message RAM to initialise.
    const gsts = model.read(unit0 + canfd.off_gsts, 4);
    try std.testing.expectEqual(@as(u32, 0), gsts & canfd.field.graminit);
    try std.testing.expect(model.quiet());
}

test "the mode machines report what was asked of them" {
    var model = canfd.Canfd.init();
    model.write(unit0 + canfd.off_gctr, 4, 2);
    try std.testing.expectEqual(canfd.field.ghltsts, model.read(unit0 + canfd.off_gsts, 4));
    model.write(unit0 + canfd.off_gctr, 4, 0);
    try std.testing.expectEqual(@as(u32, 0), model.read(unit0 + canfd.off_gsts, 4));
    model.write(unit0 + canfd.off_cnctr, 4, 2);
    try std.testing.expectEqual(canfd.field.chltsts, model.read(unit0 + canfd.off_cnsts, 4));
    model.write(unit0 + canfd.off_cnctr, 4, 1);
    try std.testing.expectEqual(canfd.field.crststs, model.read(unit0 + canfd.off_cnsts, 4));
}

test "a transmit out of operation mode moves nothing" {
    var model = canfd.Canfd.init();
    send(&model, unit0, 0x123, 8, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u32, 1), model.units[0].refused);
    try std.testing.expectEqual(@as(u32, 0), model.units[0].sent);
    try std.testing.expectEqual(canfd.field.rfemp, model.read(unit0 + canfd.off_rfsts0, 4));
    // The channel alone is not enough either.
    model.write(unit0 + canfd.off_gctr, 4, 0);
    model.write(unit0 + canfd.off_cnctr, 4, 2);
    send(&model, unit0, 0x123, 8, 0);
    try std.testing.expectEqual(@as(u32, 2), model.units[0].refused);
}

test "a frame comes back byte for byte once both machines run" {
    var model = canfd.Canfd.init();
    start(&model, unit0);
    send(&model, unit0, 0x123, 8, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u32, 1), model.units[0].sent);
    try std.testing.expectEqual(@as(u32, 1), model.units[0].received);
    try std.testing.expectEqual(canfd.field.rfif, model.read(unit0 + canfd.off_rfsts0, 4));
    try std.testing.expectEqual(@as(u32, 0x123), model.read(unit0 + canfd.off_rf0, 4));
    const ptr_word = model.read(unit0 + canfd.off_rf0 + 4, 4);
    try std.testing.expectEqual(@as(u32, 8), ptr_word >> fifo.ptr.dlc_shift);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), model.read(unit0 + canfd.off_rf0 + 12, 4));
}

test "the transmit request clears and the buffer reports completion" {
    var model = canfd.Canfd.init();
    start(&model, unit0);
    send(&model, unit0, 0x100, 2, 0);
    const tmc = model.read(unit0 + canfd.off_tmc0, 4);
    try std.testing.expectEqual(@as(u32, 0), tmc & canfd.field.tmtr);
    try std.testing.expectEqual(canfd.field.tmtrf_done, model.read(unit0 + canfd.off_tmsts0, 4));
}

test "a pop empties the FIFO and the window stops answering" {
    var model = canfd.Canfd.init();
    start(&model, unit0);
    send(&model, unit0, 0x321, 4, 0xA5A5_A5A5);
    model.write(unit0 + canfd.off_rfpctr0, 4, 0xFF);
    try std.testing.expectEqual(canfd.field.rfemp, model.read(unit0 + canfd.off_rfsts0, 4));
    try std.testing.expectEqual(@as(u32, 0), model.read(unit0 + canfd.off_rf0, 4));
    try std.testing.expectEqual(@as(u32, 0), model.units[0].starved);
}

test "a pop with nothing queued is refused" {
    var model = canfd.Canfd.init();
    start(&model, unit0);
    model.write(unit0 + canfd.off_rfpctr0, 4, 0xFF);
    try std.testing.expectEqual(@as(u32, 1), model.units[0].starved);
    try std.testing.expectEqual(canfd.field.rfemp, model.read(unit0 + canfd.off_rfsts0, 4));
}

test "two frames queue, oldest first, instead of overwriting" {
    var model = canfd.Canfd.init();
    start(&model, unit0);
    send(&model, unit0, 0x111, 1, 0x1111_1111);
    send(&model, unit0, 0x222, 2, 0x2222_2222);
    try std.testing.expectEqual(@as(u32, 0x111), model.read(unit0 + canfd.off_rf0, 4));
    model.write(unit0 + canfd.off_rfpctr0, 4, 0xFF);
    try std.testing.expectEqual(@as(u32, 0x222), model.read(unit0 + canfd.off_rf0, 4));
    try std.testing.expectEqual(@as(u32, 0x2222_2222), model.read(unit0 + canfd.off_rf0 + 12, 4));
}

test "a delivery with no stage free is counted as lost" {
    var model = canfd.Canfd.init();
    start(&model, unit0);
    for (0..fifo.depth) |index| send(&model, unit0, @intCast(index + 1), 0, 0);
    try std.testing.expectEqual(@as(u32, 0), model.units[0].lost);
    send(&model, unit0, 0x7FF, 0, 0);
    try std.testing.expectEqual(@as(u32, 1), model.units[0].lost);
    try std.testing.expectEqual(@as(u32, fifo.depth), model.units[0].received);
    // The frame still left the buffer: five transmits, four received.
    try std.testing.expectEqual(@as(u32, fifo.depth + 1), model.units[0].sent);
    try std.testing.expectEqual(@as(u32, 1), model.read(unit0 + canfd.off_rf0, 4));
}

test "a programmed filter drops the identifier it does not match" {
    var model = canfd.Canfd.init();
    start(&model, unit0);
    filter(&model, unit0, 0, 0x100, 0x7FF);
    send(&model, unit0, 0x101, 0, 0);
    try std.testing.expectEqual(@as(u32, 1), model.units[0].filtered);
    try std.testing.expectEqual(@as(u32, 0), model.units[0].received);
    try std.testing.expectEqual(canfd.field.rfemp, model.read(unit0 + canfd.off_rfsts0, 4));
    send(&model, unit0, 0x100, 0, 0);
    try std.testing.expectEqual(@as(u32, 1), model.units[0].received);
    try std.testing.expectEqual(@as(u32, 0x100), model.read(unit0 + canfd.off_rf0, 4));
}

test "an unprogrammed filter is open, as it is on dev" {
    var model = canfd.Canfd.init();
    start(&model, unit0);
    send(&model, unit0, 0x7AB, 0, 0);
    try std.testing.expectEqual(@as(u32, 1), model.units[0].received);
    try std.testing.expectEqual(@as(u32, 0), model.units[0].filtered);
}

test "a store into a status register is refused" {
    var model = canfd.Canfd.init();
    start(&model, unit0);
    model.write(unit0 + canfd.off_rfsts0, 4, canfd.field.rfif);
    model.write(unit0 + canfd.off_gsts, 4, canfd.field.ghltsts);
    model.write(unit0 + canfd.off_cnsts, 4, canfd.field.chltsts);
    model.write(unit0 + canfd.off_tmsts0, 4, canfd.field.tmtrf_done);
    try std.testing.expectEqual(@as(u32, 4), model.units[0].faked);
    try std.testing.expectEqual(canfd.field.rfemp, model.read(unit0 + canfd.off_rfsts0, 4));
    try std.testing.expectEqual(@as(u32, 0), model.read(unit0 + canfd.off_gsts, 4));
    try std.testing.expectEqual(@as(u32, 0), model.read(unit0 + canfd.off_tmsts0, 4));
}

test "a narrow write keeps the bytes it does not name" {
    var model = canfd.Canfd.init();
    model.write(unit0 + canfd.off_gctr, 4, 0x5A5A_5A00);
    model.write(unit0 + canfd.off_gctr, 1, 2);
    try std.testing.expectEqual(@as(u32, 0x5A5A_5A02), model.read(unit0 + canfd.off_gctr, 4));
    try std.testing.expectEqual(canfd.field.ghltsts, model.read(unit0 + canfd.off_gsts, 4));
    // And a narrow read names only its own byte.
    try std.testing.expectEqual(@as(u32, 0x5A), model.read(unit0 + canfd.off_gctr + 3, 1));
}

test "a byte store to the transmit request leaves the rest of the byte alone" {
    var model = canfd.Canfd.init();
    start(&model, unit0);
    model.write(unit0 + canfd.off_tmc0, 4, 0x0000_0080);
    model.write(unit0 + canfd.off_tmc0, 1, 0x81);
    try std.testing.expectEqual(@as(u32, 1), model.units[0].sent);
    try std.testing.expectEqual(@as(u32, 0x80), model.read(unit0 + canfd.off_tmc0, 4));
}

test "the two controllers keep their own state" {
    var model = canfd.Canfd.init();
    start(&model, unit1);
    send(&model, unit1, 0x0AA, 3, 0x0BAD_F00D);
    try std.testing.expectEqual(@as(u32, 1), model.units[1].received);
    try std.testing.expectEqual(@as(u32, 0), model.units[0].received);
    try std.testing.expectEqual(canfd.field.rfemp, model.read(unit0 + canfd.off_rfsts0, 4));
    try std.testing.expectEqual(@as(u32, 0x0AA), model.read(unit1 + canfd.off_rf0, 4));
    try std.testing.expectEqual(canfd.field.grststs, model.read(unit0 + canfd.off_gsts, 4));
}

test "only a delivered frame on CANFD0 earns the receive event" {
    var model = canfd.Canfd.init();
    start(&model, unit1);
    send(&model, unit1, 0x0AA, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), model.dueEvents().len);
    start(&model, unit0);
    filter(&model, unit0, 0, 0x200, 0x7FF);
    send(&model, unit0, 0x201, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), model.dueEvents().len);
    send(&model, unit0, 0x200, 0, 0);
    const due = model.dueEvents();
    try std.testing.expectEqual(@as(usize, 1), due.len);
    try std.testing.expectEqual(canfd.event.can0_rxf, due.constSlice()[0]);
    // Offered once: the line is pending until the firmware clears it.
    try std.testing.expectEqual(@as(usize, 0), model.dueEvents().len);
}

test "the block covers its own window and nothing between them" {
    var model = canfd.Canfd.init();
    const first = model.block(0);
    const second = model.block(1);
    try std.testing.expectEqual(unit0, first.base);
    try std.testing.expectEqual(unit1, second.base);
    try std.testing.expect(first.covers(unit0 + canfd.win_span - 4));
    try std.testing.expect(!first.covers(unit0 + canfd.win_span));
    try std.testing.expect(!second.covers(unit1 - 4));
    try std.testing.expectEqualStrings("CANFD0", first.name);
    try std.testing.expectEqualStrings("CANFD1", second.name);
}

test "an address outside both windows reads zero and writes nothing" {
    var model = canfd.Canfd.init();
    model.write(unit0 + canfd.win_span, 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), model.read(unit0 + canfd.win_span, 4));
    try std.testing.expect(model.quiet());
}
