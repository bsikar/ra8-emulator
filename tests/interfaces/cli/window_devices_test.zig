//! Covers src/interfaces/cli/window_devices.zig: the shown run lists the
//! Click module's parts and each `--attach`, and a pane click waits for
//! the park before it reaches the board (RA8EMU-703).
const std = @import("std");
const ra8 = @import("ra8");

const Board = ra8.board.Board;
const window_devices = ra8.board.window_devices;
const request = ra8.periph.registry.model.request;

test "click and an attach each give the pane a row" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    const attaches = [_]request.Request{try request.parse("max17048@i2c:riic@0x36")};
    var devices: window_devices.Devices = undefined;
    devices.init(std.testing.allocator, std.testing.io, &board, &attaches, true);
    defer devices.deinit();
    try std.testing.expectEqual(@as(usize, 3), devices.panel.rows.len);
    try std.testing.expectEqual(window_devices.click_imu, devices.panel.rows[0].at);
    try std.testing.expectEqual(window_devices.click_gauge, devices.panel.rows[1].at);
    try std.testing.expectEqualStrings("max17048", devices.panel.rows[2].part.?);
}

test "an unplug from the pane lands at the park" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    const attaches = [_]request.Request{try request.parse("max17048@i2c:riic@0x36")};
    var devices: window_devices.Devices = undefined;
    devices.init(std.testing.allocator, std.testing.io, &board, &attaches, false);
    defer devices.deinit();
    devices.panel.rows[0].part = null;
    try devices.panel.plug(0, "max17048");
    devices.park();
    try std.testing.expect(board.wire.controller.devices.answering(0x36) != null);
    try devices.panel.click(0);
    try std.testing.expect(board.wire.controller.devices.answering(0x36) != null);
    devices.park();
    try std.testing.expect(board.wire.controller.devices.answering(0x36) == null);
}

test "a speed change waits for the park and keeps virtual time" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var devices: window_devices.Devices = undefined;
    devices.init(std.testing.allocator, std.testing.io, &board, &.{}, false);
    defer devices.deinit();
    board.time.base.advance(5000);
    const before = board.time.base.now();
    try devices.setSpeed(0.25);
    try std.testing.expect(board.run.pacing == null);
    devices.park();
    try std.testing.expectEqual(@as(u64, 250), board.run.pacing.?.pacer.speed_milli);
    try devices.setSpeed(5);
    devices.park();
    try std.testing.expectEqual(@as(u64, 5000), board.run.pacing.?.pacer.speed_milli);
    try std.testing.expectEqual(before, board.time.base.now());
    try std.testing.expectError(error.InvalidSpeed, devices.setSpeed(0));
    try std.testing.expectError(error.InvalidSpeed, devices.setSpeed(-1));
}
