//! Independent part bytes and malformed bounds for every catalog payload.
const std = @import("std");
const ra8 = @import("ra8");
const codec = ra8.components.catalog_snapshot;
const c = ra8.components;

fn roundtrip(tag: codec.Tag, source: *anyopaque, target: *anyopaque, pins: *ra8.chip.periph.gpio.Gpio) !void {
    var saved = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer saved.deinit();
    try codec.writePayload(&saved.writer, tag, source);
    var cursor: ra8.snapshot.fields.Cursor = .{ .bytes = saved.written() };
    try codec.readPayload(tag, target, pins, &cursor);
}

test "attachment strict IMU button LED and gauge pointed guest state" {
    var pins: ra8.chip.periph.gpio.Gpio = .{};
    var imu: c.lsm6dso.Imu = .{};
    imu.write(c.lsm6dso.reg.ctrl1_xl);
    imu.write(0x40);
    imu.stop();
    imu.write(c.lsm6dso.reg.outz_l_a);
    var restored_imu: c.lsm6dso.Imu = .{};
    try roundtrip(.imu, &imu, &restored_imu, &pins);
    var expected: [2]u8 = undefined;
    var actual: [2]u8 = undefined;
    try std.testing.expectEqual(imu.read(&expected), restored_imu.read(&actual));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0x40 }, &actual);
    var button: c.button.Button = .{ .pressed = true, .link = .{ .pins = &pins, .port = 1, .pin = 4 } };
    var restored_button: c.button.Button = .{};
    try roundtrip(.button, &button, &restored_button, &pins);
    try std.testing.expect(restored_button.pressed);
    try std.testing.expect(restored_button.link.?.pins == &pins);
    try std.testing.expectEqual(@as(u8, 1), restored_button.link.?.port);
    var led: c.led.Led = .{ .lit = true, .edges = 55 };
    var restored_led: c.led.Led = .{};
    try roundtrip(.led, &led, &restored_led, &pins);
    try std.testing.expect(restored_led.lit);
    try std.testing.expectEqual(@as(u32, 55), restored_led.edges);
    var gauge = c.max17048.Gauge.powerOn();
    gauge.write(0x0c);
    gauge.write(0x12);
    var restored_gauge = c.max17048.Gauge.powerOn();
    try roundtrip(.gauge, &gauge, &restored_gauge, &pins);
    restored_gauge.write(0x34);
    try std.testing.expectEqual(@as(u16, 0x1234), restored_gauge.word(0x0c));
}

test "attachment strict panel pixels modem partial line and C6 next byte" {
    var pins: ra8.chip.periph.gpio.Gpio = .{};
    var panel: c.eink.Panel = .{};
    panel.planes.allocator = std.testing.allocator;
    panel.planes.geometry = .{ .width = 3, .height = 2 };
    defer panel.deinit();
    try std.testing.expect(panel.planes.ready());
    panel.planes.image.set(2, 1, 0xa5);
    panel.planes.glass.set(1, 0, 0x5a);
    panel.high = 0x60;
    var restored: c.eink.Panel = .{};
    restored.planes.allocator = std.testing.allocator;
    defer restored.deinit();
    try roundtrip(.panel, &panel, &restored, &pins);
    try std.testing.expectEqual(@as(u8, 0xa5), restored.planes.image.pixel(2, 1));
    try std.testing.expectEqual(@as(u8, 0x5a), restored.planes.glass.pixel(1, 0));
    try std.testing.expectEqual(panel.exchange(0), restored.exchange(0));
    var modem: c.modem_at.Modem = .{};
    _ = modem.feed('A');
    _ = modem.feed('T');
    var restored_modem: c.modem_at.Modem = .{};
    try roundtrip(.modem, &modem, &restored_modem, &pins);
    try std.testing.expectEqualSlices(u8, modem.feed(13), restored_modem.feed(13));
    var c6: c.esp_hosted.C6 = .{};
    _ = c6.wire.exchange(0);
    var restored_c6: c.esp_hosted.C6 = .{};
    try roundtrip(.c6, &c6, &restored_c6, &pins);
    try std.testing.expectEqual(c6.wire.exchange(0x56), restored_c6.wire.exchange(0x56));
}

test "attachment strict malformed pointed and panel burst payloads reject safely" {
    var pins: ra8.chip.periph.gpio.Gpio = .{};
    var imu: c.lsm6dso.Imu = .{ .pointer = 200 };
    var target: c.lsm6dso.Imu = .{};
    try std.testing.expectError(error.BadValue, roundtrip(.imu, &imu, &target, &pins));
    var panel: c.eink.Panel = .{};
    panel.burst.len = panel.burst.buf.len + 1;
    var target_panel: c.eink.Panel = .{};
    defer target_panel.deinit();
    try std.testing.expectError(error.BadValue, roundtrip(.panel, &panel, &target_panel, &pins));
    try std.testing.expectEqual(@as(usize, 0), target_panel.burst.len);
}
