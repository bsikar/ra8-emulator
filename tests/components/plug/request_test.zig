//! Covers src/components/request.zig: reading `--attach NAME@ENDPOINT`.
const std = @import("std");
const ra8 = @import("ra8");
const request = ra8.components.model.request;

test "the first '@' splits the model name from its endpoint" {
    const ask = try request.parse("max17048@i2c:touch@0x37");
    try std.testing.expectEqualStrings("max17048", ask.name);
    try std.testing.expectEqual(.touch, ask.at.i2c.line);
    try std.testing.expectEqual(@as(u7, 0x37), ask.at.i2c.address);
}

test "a name the catalog does not know is refused before the run" {
    try std.testing.expectError(error.UnknownModel, request.parse("bme280@i2c:riic@0x76"));
    try std.testing.expectError(error.NoModelName, request.parse("@i2c:riic@0x76"));
    try std.testing.expectError(error.Malformed, request.parse("lsm6dso"));
}

test "a bad endpoint keeps the endpoint's own reason" {
    try std.testing.expectError(error.ReservedAddress, request.parse("lsm6dso@i2c:riic@0x7A"));
    try std.testing.expectError(error.UnknownKind, request.parse("lsm6dso@can:0"));
}

test "an eink ask may carry WxH; no size keeps the default panel" {
    const plain = try request.parse("eink@spi:spi0@ssl0");
    try std.testing.expect(plain.geometry == null);
    const sized = try request.parse("eink:1872x1404@spi:spi0@ssl0");
    try std.testing.expectEqualStrings("eink", sized.name);
    try std.testing.expectEqual(@as(u16, 1872), sized.geometry.?.width);
    try std.testing.expectEqual(@as(u16, 1404), sized.geometry.?.height);
}

test "a size on another part, or a bad size, is refused" {
    try std.testing.expectError(request.Error.NoSizeOption, request.parse("lsm6dso:10x10@i2c:riic@0x6B"));
    try std.testing.expectError(request.Error.BadGeometry, request.parse("eink:0x10@spi:spi0@ssl0"));
    try std.testing.expectError(request.Error.NoModelName, request.parse(":10x10@spi:spi0@ssl0"));
}
