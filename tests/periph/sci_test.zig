//! Covers src/periph/sci.zig: the SCI_B channels, the console line capture and
//! the transmit-enable gate.
const std = @import("std");
const ra8 = @import("ra8");
const sci = ra8.periph.sci;

/// Open a channel the way ra8_sci_open does: receiver and transmitter on.
fn open(unit: *sci.Sci, channel: usize) void {
    unit.write(sci.regAddress(channel, sci.off_ccr0), 4, sci.ccr0.te | sci.ccr0.re);
}

fn put(unit: *sci.Sci, channel: usize, text: []const u8) void {
    for (text) |byte| unit.write(sci.regAddress(channel, sci.off_tdr), 4, byte);
}

test "the transmitter reads drained so a polled put falls through" {
    var unit = sci.Sci.init();
    open(&unit, sci.console_channel);
    const status = unit.read(sci.regAddress(sci.console_channel, sci.off_csr), 4);
    try std.testing.expect(status & sci.csr.tdre != 0);
    try std.testing.expect(status & sci.csr.tend != 0);
    try std.testing.expect(status & sci.csr.rxdmon != 0);
    try std.testing.expect(status & sci.csr.rdrf == 0);
}

test "a console line is latched on the newline that finishes it" {
    var unit = sci.Sci.init();
    open(&unit, sci.console_channel);
    put(&unit, sci.console_channel, "hello, ra8d2!\r\n");
    try std.testing.expectEqualStrings("hello, ra8d2!", unit.line.slice());
    try std.testing.expectEqual(@as(u32, 1), unit.line.lines);
    try std.testing.expectEqual(@as(u32, 15), unit.console().transmitted);
}

test "an unfinished line is not latched until its newline arrives" {
    var unit = sci.Sci.init();
    open(&unit, sci.console_channel);
    put(&unit, sci.console_channel, "first\nsecond");
    try std.testing.expectEqualStrings("first", unit.line.slice());
    put(&unit, sci.console_channel, "\n");
    try std.testing.expectEqualStrings("second", unit.line.slice());
}

test "a write with the transmitter disabled is dropped, not sent" {
    var unit = sci.Sci.init();
    put(&unit, sci.console_channel, "x");
    try std.testing.expectEqual(@as(u32, 0), unit.console().transmitted);
    try std.testing.expectEqual(@as(u32, 1), unit.console().unsent);
    try std.testing.expectEqual(@as(usize, 0), unit.line.slice().len);
}

test "a queued byte comes back out of RDR oldest first" {
    var unit = sci.Sci.init();
    open(&unit, sci.console_channel);
    unit.feed(sci.console_channel, "ok");
    try std.testing.expect(unit.read(sci.regAddress(sci.console_channel, sci.off_csr), 4) & sci.csr.rdrf != 0);
    try std.testing.expectEqual(@as(u32, 'o'), unit.read(sci.regAddress(sci.console_channel, sci.off_rdr), 4));
    try std.testing.expectEqual(@as(u32, 'k'), unit.read(sci.regAddress(sci.console_channel, sci.off_rdr), 4));
    try std.testing.expectEqual(@as(u32, 0), unit.read(sci.regAddress(sci.console_channel, sci.off_rdr), 4));
    try std.testing.expectEqual(@as(u32, 2), unit.console().received);
}

test "a queued byte stays queued while the receiver is disabled" {
    var unit = sci.Sci.init();
    unit.write(sci.regAddress(sci.console_channel, sci.off_ccr0), 4, sci.ccr0.te);
    unit.feed(sci.console_channel, "z");
    try std.testing.expect(unit.read(sci.regAddress(sci.console_channel, sci.off_csr), 4) & sci.csr.rdrf == 0);
    try std.testing.expectEqual(@as(u32, 0), unit.read(sci.regAddress(sci.console_channel, sci.off_rdr), 4));
    open(&unit, sci.console_channel);
    try std.testing.expectEqual(@as(u32, 'z'), unit.read(sci.regAddress(sci.console_channel, sci.off_rdr), 4));
}

test "the FIFO status registers follow the same queue" {
    var unit = sci.Sci.init();
    open(&unit, sci.console_channel);
    try std.testing.expectEqual(@as(u32, 0), unit.read(sci.regAddress(sci.console_channel, sci.off_frsr), 4));
    unit.feed(sci.console_channel, "a");
    const frsr = unit.read(sci.regAddress(sci.console_channel, sci.off_frsr), 4);
    try std.testing.expect(frsr & sci.fifo.frsr_dr != 0);
    try std.testing.expect(frsr & sci.fifo.frsr_rdf != 0);
    const ftsr = unit.read(sci.regAddress(sci.console_channel, sci.off_ftsr), 4);
    try std.testing.expect(ftsr & sci.fifo.ftsr_tdfe != 0);
}

test "the flag-clear strobes read zero and clear nothing derived" {
    var unit = sci.Sci.init();
    open(&unit, sci.console_channel);
    unit.feed(sci.console_channel, "q");
    unit.write(sci.regAddress(sci.console_channel, sci.off_cfclr), 4, 0x8000_0000);
    unit.write(sci.regAddress(sci.console_channel, sci.off_ffclr), 4, 0x0000_0001);
    try std.testing.expectEqual(@as(u32, 0), unit.read(sci.regAddress(sci.console_channel, sci.off_cfclr), 4));
    try std.testing.expectEqual(@as(u32, 0), unit.read(sci.regAddress(sci.console_channel, sci.off_ffclr), 4));
    try std.testing.expect(unit.read(sci.regAddress(sci.console_channel, sci.off_csr), 4) & sci.csr.rdrf != 0);
}

test "channels do not share state" {
    var unit = sci.Sci.init();
    open(&unit, 0);
    open(&unit, sci.console_channel);
    put(&unit, 0, "binary");
    unit.feed(0, "r");
    try std.testing.expectEqual(@as(u32, 6), unit.channels[0].transmitted);
    try std.testing.expectEqual(@as(u32, 0), unit.console().transmitted);
    // Only the console channel carries text; SCI0 moves SPI frames, so its
    // traffic never reaches the line buffer.
    try std.testing.expectEqual(@as(usize, 0), unit.line.slice().len);
    try std.testing.expectEqual(@as(u32, 'r'), unit.read(sci.regAddress(0, sci.off_rdr), 4));
}

test "the control shadow reads back what the driver wrote" {
    var unit = sci.Sci.init();
    const value = sci.ccr0.te | sci.ccr0.re | sci.ccr0.rie;
    unit.write(sci.regAddress(3, sci.off_ccr0), 4, value);
    try std.testing.expectEqual(value, unit.read(sci.regAddress(3, sci.off_ccr0), 4));
    try std.testing.expect(unit.channels[3].enabled(sci.ccr0.rie));
    try std.testing.expect(!unit.channels[3].enabled(sci.ccr0.tie));
}

test "a full RX ring drops the rest instead of wrapping over unread bytes" {
    var ring = sci.Ring{};
    var payload: [sci.limits.rx_queue]u8 = undefined;
    @memset(&payload, 'x');
    ring.push(&payload);
    try std.testing.expectEqual(@as(u32, 1), ring.dropped);
    try std.testing.expectEqual(@as(u8, 'x'), ring.pop().?);
}

test "an over-long line stops growing rather than wrapping onto itself" {
    var line = sci.Line{};
    for (0..sci.limits.line + 8) |_| line.feed('a');
    line.feed('\n');
    try std.testing.expectEqual(sci.limits.line, line.slice().len);
}

test "an untouched block stays out of the report" {
    var unit = sci.Sci.init();
    try std.testing.expect(unit.quiet());
    open(&unit, 1);
    try std.testing.expect(unit.quiet());
    put(&unit, 1, "!");
    try std.testing.expect(!unit.quiet());
}

test "the block covers every channel and nothing past the last one" {
    var unit = sci.Sci.init();
    const block = unit.block();
    try std.testing.expectEqual(sci.win_base, block.base);
    try std.testing.expectEqual(sci.win_span, block.size);
    try std.testing.expect(block.covers(sci.regAddress(sci.channels - 1, sci.off_csr)));
    try std.testing.expect(!block.covers(sci.win_base + sci.win_span));
}

test "no console event is due until the firmware arms one" {
    var unit = sci.Sci.init();
    try std.testing.expectEqual(@as(usize, 0), unit.dueEvents().len);
}

test "TXI and TEI are due while their enables stand with TE" {
    var unit = sci.Sci.init();
    unit.write(sci.regAddress(sci.console_channel, sci.off_ccr0), 4, sci.ccr0.te | sci.ccr0.tie | sci.ccr0.teie);
    const due = unit.dueEvents();
    try std.testing.expectEqual(@as(usize, 2), due.len);
    try std.testing.expectEqual(sci.event.txi, due.constSlice()[0]);
    try std.testing.expectEqual(sci.event.tei, due.constSlice()[1]);
}

test "an armed transmit interrupt with TE clear is not due" {
    var unit = sci.Sci.init();
    unit.write(sci.regAddress(sci.console_channel, sci.off_ccr0), 4, sci.ccr0.tie | sci.ccr0.teie);
    try std.testing.expectEqual(@as(usize, 0), unit.dueEvents().len);
}

test "RXI is due only while a byte is actually queued" {
    var unit = sci.Sci.init();
    unit.write(sci.regAddress(sci.console_channel, sci.off_ccr0), 4, sci.ccr0.re | sci.ccr0.rie);
    try std.testing.expectEqual(@as(usize, 0), unit.dueEvents().len);

    unit.feed(sci.console_channel, "x");
    const due = unit.dueEvents();
    try std.testing.expectEqual(@as(usize, 1), due.len);
    try std.testing.expectEqual(sci.event.rxi, due.constSlice()[0]);

    _ = unit.read(sci.regAddress(sci.console_channel, sci.off_rdr), 4);
    try std.testing.expectEqual(@as(usize, 0), unit.dueEvents().len);
}

test "only the console channel raises events" {
    var unit = sci.Sci.init();
    unit.write(sci.regAddress(0, sci.off_ccr0), 4, sci.ccr0.te | sci.ccr0.tie);
    try std.testing.expectEqual(@as(usize, 0), unit.dueEvents().len);
}
