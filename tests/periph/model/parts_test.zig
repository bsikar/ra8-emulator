//! Covers src/periph/model/parts.zig: the Click parts as catalog models,
//! each instance its own part at its own address.
const std = @import("std");
const ra8 = @import("ra8");
const model = ra8.periph.registry.model;
const parts = model.parts;
const endpoint = model.endpoint;
const catalog = model.catalog;
const lsm6dso = ra8.components.lsm6dso;
const max17048 = ra8.components.max17048;

test "the catalog knows the IMU and the fuel gauge as I2C models" {
    const imu = parts.all.find(parts.imu_name) orelse return error.Missing;
    const gauge = parts.all.find(parts.gauge_name) orelse return error.Missing;
    try std.testing.expectEqual(endpoint.Kind.i2c, imu.kind);
    try std.testing.expectEqual(endpoint.Kind.i2c, gauge.kind);
}

test "a made IMU answers WHO_AM_I at the endpoint's address" {
    const allocator = std.testing.allocator;
    const made = try parts.all.make(allocator, parts.imu_name, try endpoint.parse("i2c:touch@0x6A"));
    defer catalog.Catalog.destroy(allocator, made);
    const device = made.device.i2c;
    try std.testing.expectEqual(@as(u7, 0x6A), device.address);
    device.write(lsm6dso.reg.who_am_i);
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), device.read(&byte));
    try std.testing.expectEqual(lsm6dso.identity, byte[0]);
    device.stop();
}

test "two gauges are two parts" {
    const allocator = std.testing.allocator;
    const first = try parts.all.make(allocator, parts.gauge_name, try endpoint.parse("i2c:touch@0x36"));
    defer catalog.Catalog.destroy(allocator, first);
    const second = try parts.all.make(allocator, parts.gauge_name, try endpoint.parse("i2c:touch@0x37"));
    defer catalog.Catalog.destroy(allocator, second);
    try std.testing.expect(first.state != second.state);
    try std.testing.expectEqual(@as(u7, max17048.address), first.device.i2c.address);
    try std.testing.expectEqual(@as(u7, 0x37), second.device.i2c.address);
}

test "binding a part the board holds leaves it the one that answers" {
    var held: lsm6dso.Imu = .{};
    const device = try parts.all.bind(parts.imu_name, &held, try endpoint.parse("i2c:touch@0x6B"));
    device.i2c.write(lsm6dso.reg.who_am_i);
    var byte: [1]u8 = undefined;
    _ = device.i2c.read(&byte);
    try std.testing.expectEqual(lsm6dso.identity, byte[0]);
    try std.testing.expect(held.reads != 0 or held.writes != 0 or !held.quiet());
}

test "a made gauge comes up at power-on, not zeroed" {
    const allocator = std.testing.allocator;
    const made = try parts.all.make(allocator, parts.gauge_name, try endpoint.parse("i2c:touch@0x36"));
    defer catalog.Catalog.destroy(allocator, made);
    const gauge: *const max17048.Gauge = @ptrCast(@alignCast(made.state));
    const soc: u16 = @as(u16, max17048.cell.default_soc) << max17048.cell.percent_shift;
    try std.testing.expectEqual(soc, gauge.word(max17048.reg.soc));
    try std.testing.expectEqual(max17048.cell.vcell, gauge.word(max17048.reg.vcell));
    const rate: u16 = @bitCast(-max17048.cell.crate_magnitude);
    try std.testing.expectEqual(rate, gauge.word(max17048.reg.crate));
}
