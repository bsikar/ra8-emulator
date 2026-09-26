//! The MAX17048 fuel gauge: the words the battery state lays down, the
//! registers the gauge owns, and what it refuses.
const std = @import("std");
const ra8 = @import("ra8");
const max17048 = ra8.periph.i3c_max17048;

fn gaugeAt(soc: u8, charging: bool) !max17048.Gauge {
    return max17048.Gauge.init(.{ .soc_pct = soc, .charging = charging });
}

test "the state-of-charge register carries the percent the run asked for" {
    var gauge = try gaugeAt(64, false);
    try std.testing.expectEqual(@as(u16, 64) << 8, gauge.word(max17048.reg.soc));
}

test "a percent over full is refused, not clamped" {
    try std.testing.expectError(max17048.Error.SocOutOfRange, gaugeAt(120, false));
}

test "the charge rate carries the direction" {
    var charging = try gaugeAt(50, true);
    var flat = try gaugeAt(50, false);
    const up: i16 = @bitCast(charging.word(max17048.reg.crate));
    const down: i16 = @bitCast(flat.word(max17048.reg.crate));
    try std.testing.expect(up > 0);
    try std.testing.expect(down < 0);
}

test "a read serves the register the pointer names" {
    var gauge = try gaugeAt(72, false);
    gauge.write(max17048.reg.version);
    var buffer: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), gauge.read(buffer[0..]));
    const value = @as(u16, buffer[0]) << 8 | buffer[1];
    try std.testing.expectEqual(max17048.cell.version, value);
    try std.testing.expectEqual(@as(u32, 1), gauge.reads);
}

test "a read walks on through the following registers" {
    var gauge = try gaugeAt(72, false);
    gauge.write(max17048.reg.vcell);
    var buffer: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), gauge.read(buffer[0..]));
    const soc = @as(u16, buffer[2]) << 8 | buffer[3];
    try std.testing.expectEqual(@as(u16, 72) << 8, soc);
}

test "a pointer inside a word is refused" {
    var gauge = try gaugeAt(72, false);
    gauge.write(max17048.reg.soc + 1);
    try std.testing.expectEqual(@as(u32, 1), gauge.misaligned);
    try std.testing.expect(!gauge.pointed);
}

test "a register the part does not have is refused" {
    var gauge = try gaugeAt(72, false);
    gauge.write(0x40);
    try std.testing.expectEqual(@as(u32, 1), gauge.unmapped);
    try std.testing.expect(!gauge.pointed);
}

test "a store over the state-of-charge is refused" {
    var gauge = try gaugeAt(72, false);
    gauge.write(max17048.reg.soc);
    gauge.write(0x63);
    gauge.write(0x00);
    try std.testing.expectEqual(@as(u32, 1), gauge.read_only);
    try std.testing.expectEqual(@as(u16, 72) << 8, gauge.word(max17048.reg.soc));
}

test "a store into config lands" {
    var gauge = try gaugeAt(72, false);
    gauge.write(max17048.reg.config);
    gauge.write(0x97);
    gauge.write(0x1C);
    try std.testing.expectEqual(@as(u16, 0x971C), gauge.word(max17048.reg.config));
    try std.testing.expectEqual(@as(u32, 1), gauge.writes);
}

test "a half-written word is lost at stop rather than landing" {
    var gauge = try gaugeAt(72, false);
    gauge.write(max17048.reg.config);
    gauge.write(0x97);
    gauge.stop();
    try std.testing.expectEqual(@as(u32, 1), gauge.torn);
    try std.testing.expectEqual(@as(u16, 0), gauge.word(max17048.reg.config));
}

test "the power-on-reset command lays the file down again" {
    var gauge = try gaugeAt(72, false);
    gauge.write(max17048.reg.config);
    gauge.write(0x97);
    gauge.write(0x1C);
    gauge.stop();
    gauge.write(max17048.reg.command);
    gauge.write(@truncate(max17048.power_on_reset >> 8));
    gauge.write(@truncate(max17048.power_on_reset));
    try std.testing.expectEqual(@as(u32, 1), gauge.resets);
    try std.testing.expectEqual(@as(u16, 0), gauge.word(max17048.reg.config));
    try std.testing.expectEqual(@as(u16, 72) << 8, gauge.word(max17048.reg.soc));
}

test "a command word that is not the reset does nothing" {
    var gauge = try gaugeAt(72, false);
    gauge.write(max17048.reg.command);
    gauge.write(0x00);
    gauge.write(0x01);
    try std.testing.expectEqual(@as(u32, 0), gauge.resets);
    try std.testing.expectEqual(@as(u32, 0), gauge.writes);
}

test "the command register answers nothing to a read" {
    var gauge = try gaugeAt(72, false);
    gauge.write(max17048.reg.command);
    var buffer: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), gauge.read(buffer[0..]));
    try std.testing.expectEqual(@as(u32, 1), gauge.unmapped);
}

test "a burst stops at the end of the mapped space" {
    var gauge = try gaugeAt(72, false);
    gauge.write(max17048.reg.status);
    var buffer: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), gauge.read(buffer[0..]));
}

test "a gauge nobody read is quiet" {
    var gauge = try gaugeAt(72, false);
    try std.testing.expect(gauge.quiet());
    gauge.write(max17048.reg.soc);
    var buffer: [2]u8 = undefined;
    _ = gauge.read(buffer[0..]);
    try std.testing.expect(!gauge.quiet());
}

test "the device seam answers at the part's address" {
    var gauge = try gaugeAt(72, false);
    const device = gauge.device();
    try std.testing.expectEqual(max17048.address, device.address);
    device.write(max17048.reg.soc);
    var buffer: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), device.read(buffer[0..]));
    try std.testing.expectEqual(@as(u8, 72), buffer[0]);
    device.stop();
}

test "a later battery state re-lays the register file" {
    var gauge = try gaugeAt(72, false);
    try gauge.setBattery(.{ .soc_pct = 9, .charging = true });
    try std.testing.expectEqual(@as(u16, 9) << 8, gauge.word(max17048.reg.soc));
    const rate: i16 = @bitCast(gauge.word(max17048.reg.crate));
    try std.testing.expect(rate > 0);
}
