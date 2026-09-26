//! Covers src/periph/ssie.zig.
const std = @import("std");
const ssie = @import("ra8").periph.ssie;

const ch0 = ssie.channelAddress(0);
const ch1 = ssie.channelAddress(1);

fn unit() ssie.Ssie {
    return ssie.Ssie.init();
}

/// Start the transmitter the way a driver does: read SSISR for the idle
/// flag, then set TEN.
fn startTx(block: *ssie.Ssie, base: u32) !void {
    try std.testing.expect(block.read(base + ssie.off_ssisr, 4) & ssie.field.iirq != 0);
    block.write(base + ssie.off_ssicr, 4, ssie.field.ten);
}

test "a fresh channel is idle, empty and quiet" {
    var block = unit();
    try std.testing.expectEqual(ssie.field.iirq, block.read(ch0 + ssie.off_ssisr, 4));
    try std.testing.expectEqual(ssie.field.tde, block.read(ch0 + ssie.off_ssifsr, 4));
    try std.testing.expect(block.quiet());
}

test "IIRQ drops once either direction is enabled, and comes back" {
    var block = unit();
    block.write(ch0 + ssie.off_ssicr, 4, ssie.field.ren);
    try std.testing.expectEqual(@as(u32, 0), block.read(ch0 + ssie.off_ssisr, 4));
    block.write(ch0 + ssie.off_ssicr, 4, 0);
    try std.testing.expectEqual(ssie.field.iirq, block.read(ch0 + ssie.off_ssisr, 4));
}

test "a sample written with TEN set is transmitted" {
    var block = unit();
    try startTx(&block, ch0);
    block.write(ch0 + ssie.off_ssiftdr, 4, 0x1234_5678);
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].transmitted);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), block.channels[0].last);
    try std.testing.expectEqual(@as(usize, 0), block.channels[0].staged);
}

test "a sample written with TEN clear is staged, not transmitted" {
    var block = unit();
    block.write(ch0 + ssie.off_ssiftdr, 4, 0x0AAA);
    try std.testing.expectEqual(@as(u32, 0), block.channels[0].transmitted);
    try std.testing.expectEqual(@as(usize, 1), block.channels[0].staged);
}

test "TDE reads clear while the FIFO holds a sample" {
    var block = unit();
    block.write(ch0 + ssie.off_ssiftdr, 4, 1);
    try std.testing.expectEqual(@as(u32, 0), block.read(ch0 + ssie.off_ssifsr, 4));
    try startTx(&block, ch0);
    try std.testing.expectEqual(ssie.field.tde, block.read(ch0 + ssie.off_ssifsr, 4));
}

test "setting TEN drains what is staged, oldest first" {
    var block = unit();
    block.write(ch0 + ssie.off_ssiftdr, 4, 0x11);
    block.write(ch0 + ssie.off_ssiftdr, 4, 0x22);
    try startTx(&block, ch0);
    try std.testing.expectEqual(@as(u32, 2), block.channels[0].transmitted);
    try std.testing.expectEqual(@as(u32, 0x22), block.channels[0].last);
    try std.testing.expectEqual(@as(usize, 0), block.channels[0].staged);
}

test "a store past the last stage is dropped, not transmitted" {
    var block = unit();
    for (0..ssie.tx_depth + 3) |i| {
        block.write(ch0 + ssie.off_ssiftdr, 4, @intCast(i));
    }
    try std.testing.expectEqual(ssie.tx_depth, block.channels[0].staged);
    try std.testing.expectEqual(@as(u32, 3), block.channels[0].dropped);
    try startTx(&block, ch0);
    try std.testing.expectEqual(@as(u32, ssie.tx_depth), block.channels[0].transmitted);
}

test "a byte store to TEN leaves the rest of SSICR where it was" {
    var block = unit();
    block.write(ch0 + ssie.off_ssicr, 4, 0x5A5A_5A00);
    block.write(ch0 + ssie.off_ssicr, 1, ssie.field.ten);
    try std.testing.expectEqual(@as(u32, 0x5A5A_5A02), block.read(ch0 + ssie.off_ssicr, 4));
    try std.testing.expect(block.channels[0].transmitting());
}

test "a store to SSISR changes nothing a read can see" {
    var block = unit();
    block.write(ch0 + ssie.off_ssisr, 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(ssie.field.iirq, block.read(ch0 + ssie.off_ssisr, 4));
    try startTx(&block, ch0);
    block.write(ch0 + ssie.off_ssisr, 4, ssie.field.iirq);
    try std.testing.expectEqual(@as(u32, 0), block.read(ch0 + ssie.off_ssisr, 4));
}

test "an unmodelled register reads back what was written to it" {
    var block = unit();
    block.write(ch0 + ssie.off_ssifcr, 4, 0x0000_0033);
    try std.testing.expectEqual(@as(u32, 0x0000_0033), block.read(ch0 + ssie.off_ssifcr, 4));
    block.write(ch0 + ssie.off_ssifcr, 1, 0x44);
    try std.testing.expectEqual(@as(u32, 0x0000_0044), block.read(ch0 + ssie.off_ssifcr, 4));
}

test "the receive port has no source behind it" {
    var block = unit();
    try std.testing.expectEqual(@as(u32, 0), block.read(ch0 + ssie.off_ssifrdr, 4));
}

test "the channels are separate" {
    var block = unit();
    try startTx(&block, ch1);
    block.write(ch1 + ssie.off_ssiftdr, 4, 0x77);
    try std.testing.expectEqual(@as(u32, 1), block.channels[1].transmitted);
    try std.testing.expectEqual(@as(u32, 0), block.channels[0].transmitted);
    try std.testing.expect(block.channels[0].quiet());
    try std.testing.expect(!block.quiet());
}

test "a channel outside the window is not decoded" {
    var block = unit();
    block.write(ssie.win_base + ssie.win_span, 4, 0xFFFF);
    try std.testing.expect(block.quiet());
}
