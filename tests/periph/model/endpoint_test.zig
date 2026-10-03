//! Covers src/periph/model/endpoint.zig: the text form a run names a model's
//! endpoint with, and what it refuses.
const std = @import("std");
const ra8 = @import("ra8");
const endpoint = ra8.periph.registry.model.endpoint;

test "an I2C endpoint names its line and a 7-bit address" {
    const at = try endpoint.parse("i2c:touch@0x36");
    try std.testing.expectEqual(endpoint.Kind.i2c, at.kind());
    try std.testing.expectEqual(endpoint.Line.touch, at.i2c.line);
    try std.testing.expectEqual(@as(u7, 0x36), at.i2c.address);
    const decimal = try endpoint.parse("i2c:riic@32");
    try std.testing.expectEqual(endpoint.Line.riic, decimal.i2c.line);
    try std.testing.expectEqual(@as(u7, 32), decimal.i2c.address);
}

test "an I2C endpoint refuses reserved, too-wide and unknown-line addresses" {
    try std.testing.expectError(error.ReservedAddress, endpoint.parse("i2c:riic@0x00"));
    try std.testing.expectError(error.ReservedAddress, endpoint.parse("i2c:riic@0x78"));
    try std.testing.expectError(error.OutOfRange, endpoint.parse("i2c:riic@0x80"));
    try std.testing.expectError(error.UnknownLine, endpoint.parse("i2c:sda@0x36"));
    try std.testing.expectError(error.BadNumber, endpoint.parse("i2c:riic@x"));
    try std.testing.expectError(error.Malformed, endpoint.parse("i2c:riic"));
}

test "an SPI endpoint names a channel and a slave select" {
    const at = try endpoint.parse("spi:spi1@ssl3");
    try std.testing.expectEqual(@as(u1, 1), at.spi.channel);
    try std.testing.expectEqual(@as(u2, 3), at.spi.select);
    try std.testing.expectError(error.OutOfRange, endpoint.parse("spi:spi2@ssl0"));
    try std.testing.expectError(error.OutOfRange, endpoint.parse("spi:spi0@ssl4"));
    try std.testing.expectError(error.Malformed, endpoint.parse("spi:spi0"));
}

test "a UART endpoint names an SCI channel" {
    const at = try endpoint.parse("uart:sci9");
    try std.testing.expectEqual(endpoint.Kind.uart, at.kind());
    try std.testing.expectEqual(@as(u4, 9), at.uart.channel);
    try std.testing.expectError(error.OutOfRange, endpoint.parse("uart:sci10"));
    try std.testing.expectError(error.Malformed, endpoint.parse("uart:uart3"));
}

test "a GPIO endpoint takes the RA pin name" {
    const at = try endpoint.parse("gpio:P006");
    try std.testing.expectEqual(@as(u4, 0), at.gpio.port);
    try std.testing.expectEqual(@as(u4, 6), at.gpio.pin);
    const high = try endpoint.parse("gpio:PB15");
    try std.testing.expectEqual(@as(u4, 0xB), high.gpio.port);
    try std.testing.expectEqual(@as(u4, 15), high.gpio.pin);
    try std.testing.expectError(error.OutOfRange, endpoint.parse("gpio:PC00"));
    try std.testing.expectError(error.OutOfRange, endpoint.parse("gpio:P016"));
    try std.testing.expectError(error.Malformed, endpoint.parse("gpio:006"));
}

test "a missing or unknown kind is refused" {
    try std.testing.expectError(error.Malformed, endpoint.parse("i2c"));
    try std.testing.expectError(error.Malformed, endpoint.parse("i2c:"));
    try std.testing.expectError(error.UnknownKind, endpoint.parse("can:can0"));
}
