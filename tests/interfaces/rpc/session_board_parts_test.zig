//! Host tests for the board_parts handler (RA8EMU-1151): the served board's
//! front-panel parts, the LED labels in the chip's led_changed order with
//! the chip's lamp colours, the switch labels in the board's switch order,
//! and the panel profile; plus the codec round-trip.
const std = @import("std");
const ra8 = @import("ra8");
const proto = ra8.rpc.session.rpc;
const server = ra8.rpc.session.server;
const parts = ra8.rpc.session.parts;
const api = ra8.session.api;
const chip_gpio = ra8.chip.periph.gpio;
const board_lib = ra8.board;

fn code(outcome: anytype) u16 {
    return switch (outcome) {
        .ok => 0,
        .err => |refused| @backingInt(refused),
    };
}

fn answer(scratch: []u8) !proto.BoardParts {
    var session: api.Session = .{ .live = undefined };
    var context: server.Context = .{ .session = &session, .scratch = scratch };
    const outcome = parts.boardParts(&context, .{ .core = .cpu0 });
    return switch (outcome) {
        .ok => |given| given,
        .err => error.Refused,
    };
}

fn lines(text: []const u8) usize {
    if (text.len == 0) return 0;
    var total: usize = 1;
    for (text) |byte| {
        if (byte == '\n') total += 1;
    }
    return total;
}

fn line(text: []const u8, index: usize) []const u8 {
    var start: usize = 0;
    var seen: usize = 0;
    for (text, 0..) |byte, end| {
        if (byte != '\n') continue;
        if (seen == index) return text[start..end];
        seen += 1;
        start = end + 1;
    }
    return if (seen == index) text[start..] else "";
}

test "board_parts answers with the served board's front-panel parts" {
    var scratch: [proto.max_payload]u8 = undefined;
    const given = try answer(&scratch);
    try std.testing.expectEqual(@as(usize, chip_gpio.led_count), lines(given.led_names));
    try std.testing.expectEqual(chip_gpio.led_count * 2, given.led_colors.len);
    // The LEDs come in the chip's led_changed order, each with the chip's
    // lamp colour and the profile's label, so led_changed and the pane agree.
    const profile = try board_lib.profile.parse(board_lib.profile.ek_ra8d2);
    for (chip_gpio.leds, 0..) |led, index| {
        const entry = profile.ledAt(led.port, led.pin) orelse return error.UntrackedLed;
        try std.testing.expectEqual(led.rgb565, std.mem.readInt(u16, given.led_colors[index * 2 ..][0..2], .little));
        try std.testing.expectEqualStrings(entry.label, line(given.led_names, index));
    }
    try std.testing.expectEqual(board_lib.switches.user.len, lines(given.switch_names));
    for (board_lib.switches.user, 0..) |one, index| {
        const entry = profile.switchAt(one.port, one.pin) orelse return error.UntrackedSwitch;
        try std.testing.expectEqualStrings(entry.label, line(given.switch_names, index));
    }
    // The panel profile the pre-frame slot fits: the ER-TFT070-6 glass.
    try std.testing.expectEqualStrings("ER-TFT070-6", given.panel);
    try std.testing.expectEqual(@as(u32, 1024), given.panel_width);
    try std.testing.expectEqual(@as(u32, 600), given.panel_height);
}

test "a board parts answer round-trips through the codec" {
    var bytes: [256]u8 = undefined;
    const payload = try proto.encode(proto.BoardParts, .{
        .panel = "ek_ra8d2",
        .panel_width = 1024,
        .panel_height = 600,
        .led_names = "LED1 BLUE\nLED2 GREEN\nLED3 RED",
        .led_colors = &(@as([6]u8, @splat(0))),
        .switch_names = "SW1\nSW2",
    }, &bytes);
    const back = try proto.decode(proto.BoardParts, payload);
    try std.testing.expectEqualStrings("ek_ra8d2", back.panel);
    try std.testing.expectEqual(@as(u32, 1024), back.panel_width);
    try std.testing.expectEqual(@as(u32, 600), back.panel_height);
    try std.testing.expectEqualStrings("LED1 BLUE\nLED2 GREEN\nLED3 RED", back.led_names);
    try std.testing.expectEqual(@as(usize, 6), back.led_colors.len);
    try std.testing.expectEqualStrings("SW1\nSW2", back.switch_names);
}
