//! Tests for src/board/i2c.zig: which parts the board puts on its two lines,
//! and that the Click-module parts answer only when a run fits the module.
const std = @import("std");
const ra8 = @import("ra8");

const i2c = ra8.board.i2c;
const periph = ra8.periph.registry;
const gt911 = ra8.periph.i3c_gt911;
const lsm6dso = ra8.periph.i3c_lsm6dso;
const max17048 = ra8.periph.i3c_max17048;

test "a default board answers nothing at the IMU or fuel gauge address" {
    var bus = periph.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var wire = i2c.Wire{};
    try wire.attach(&bus);
    try std.testing.expect(wire.touchline.devices.find(lsm6dso.address) == null);
    try std.testing.expect(wire.touchline.devices.find(max17048.address) == null);
}

test "a default board still carries the touch panel" {
    var bus = periph.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var wire = i2c.Wire{};
    try wire.attach(&bus);
    try std.testing.expect(wire.touchline.devices.find(gt911.address) != null);
}

test "fitting the Click module puts the IMU and the fuel gauge on the line" {
    var bus = periph.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var wire = i2c.Wire{ .click = true };
    try wire.attach(&bus);
    try std.testing.expect(wire.touchline.devices.find(lsm6dso.address) != null);
    try std.testing.expect(wire.touchline.devices.find(max17048.address) != null);
    try std.testing.expect(wire.touchline.devices.find(gt911.address) != null);
}
