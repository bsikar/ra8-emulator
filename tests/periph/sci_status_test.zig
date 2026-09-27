//! Covers src/periph/sci_status.zig: what the SCI status words report, and
//! which words in the channel window the controller owns.
const std = @import("std");
const ra8 = @import("ra8");
const status = ra8.periph.sci_status;

test "CSR idles with the transmitter drained and the line high" {
    const idle = status.common(false);
    try std.testing.expect(idle & status.csr.tdre != 0);
    try std.testing.expect(idle & status.csr.tend != 0);
    try std.testing.expect(idle & status.csr.rxdmon != 0);
    try std.testing.expectEqual(@as(u32, 0), idle & status.csr.rdrf);
}

test "RDRF follows the receive queue rather than a value firmware wrote" {
    try std.testing.expect(status.common(true) & status.csr.rdrf != 0);
}

test "FRSR reports a byte waiting only when one is" {
    try std.testing.expectEqual(@as(u32, 0), status.receive(false));
    const waiting = status.receive(true);
    try std.testing.expect(waiting & status.fifo.frsr_dr != 0);
    try std.testing.expect(waiting & status.fifo.frsr_rdf != 0);
}

test "the transmit FIFO reads empty, the same reason TDRE reads set" {
    try std.testing.expect(status.transmit & status.fifo.ftsr_tdfe != 0);
}

test "the error flags read clear because nothing here can raise one" {
    // ORER, FER and PER: no baud clock to frame against, no line to hear
    // noise on. A driver's error path is never entered on an invented fault.
    const errors: u32 = 0x0100_0000 | 0x0200_0000 | 0x0400_0000;
    try std.testing.expectEqual(@as(u32, 0), status.common(true) & errors);
}

test "the status words are the controller's and the strobes are not" {
    try std.testing.expect(status.readOnly(status.off.csr));
    try std.testing.expect(status.readOnly(status.off.frsr));
    try std.testing.expect(status.readOnly(status.off.ftsr));
    try std.testing.expect(!status.readOnly(status.off.cfclr));
    try std.testing.expect(!status.readOnly(status.off.ffclr));
    try std.testing.expect(status.clearStrobe(status.off.cfclr));
    try std.testing.expect(status.clearStrobe(status.off.ffclr));
    try std.testing.expect(!status.clearStrobe(status.off.csr));
}
