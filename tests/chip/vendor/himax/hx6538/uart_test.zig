//! Covers src/chip/vendor/himax/hx6538/uart.zig: DW APB UART registers, console TX, and loopback RX.
const ra8 = @import("ra8");
const std = @import("std");

const sci_line = ra8.chip.periph.sci.line;
const uart = ra8.chip.vendor.himax.hx6538.uart;

test "DW APB UART exposes CPR/LSR/DLAB, emits TX lines to console, and supports loopback RX" {
    var line: sci_line.Line = .{};
    var ch: uart.Uart = .{ .console = &line };

    try std.testing.expectEqual(uart.bits.cpr_reset, ch.read(uart.regs.cpr));
    try std.testing.expectEqual(uart.bits.lsr_tx_empty, ch.read(uart.regs.lsr));

    ch.write(uart.regs.lcr, uart.bits.lcr_dlab | 0x03);
    ch.write(uart.regs.rbr_thr_dll, 0x0D);
    ch.write(uart.regs.ier_dlh, 0x00);
    try std.testing.expectEqual(@as(u32, 0x0D), ch.read(uart.regs.rbr_thr_dll));
    ch.write(uart.regs.lcr, 0x03);

    for ("hx6538-ok\n") |b| ch.write(uart.regs.rbr_thr_dll, b);
    try std.testing.expectEqual(@as(u32, 1), line.lines);
    try std.testing.expectEqualStrings("hx6538-ok", line.slice());

    // Loopback + ERBFI interrupt
    ch.write(uart.regs.mcr, uart.bits.mcr_loop);
    ch.write(uart.regs.ier_dlh, uart.bits.ier_erbfi);
    ch.write(uart.regs.rbr_thr_dll, 'A');
    try std.testing.expect(ch.irqAsserted());
    try std.testing.expectEqual(@as(u32, 0x04), ch.read(uart.regs.iir_fcr) & 0x0F);
    try std.testing.expectEqual(@as(u32, 'A'), ch.read(uart.regs.rbr_thr_dll));
    try std.testing.expect(!ch.irqAsserted());
}
