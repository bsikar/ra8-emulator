//! Host tests for the chosen board profile (RA8EMU-1152): board_parts
//! answers the profile the session was opened with, so the pane draws the
//! board the profile names and never a built-in default.
const std = @import("std");
const ra8 = @import("ra8");
const proto = ra8.rpc.session.rpc;
const server = ra8.rpc.session.server;
const parts = ra8.rpc.session.parts;
const api = ra8.session.api;
const board_lib = ra8.board;

/// A board that is not the shipped EK-RA8D2 default: its own memory, its
/// own tracked pads and the small shipped panel.
const custom =
    \\# Test board, profile format version 1.
    \\version=1
    \\ospi=size:16777216,width:8,clock_hz:166666667,latency_cycles:8,burst:incrementing16
    \\sdram=size:8388608,width:32,clock_hz:133000000,latency_cycles:3,burst:incrementing16
    \\memory_window_cycles=1000000
    \\led=P600,0x001F,TEST LED
    \\switch=P009,SW9
    \\panel=sample_480x272
    \\companion=c6@uart:sci2
;

test "board_parts serves the chosen board profile" {
    var scratch: [proto.max_payload]u8 = undefined;
    var session: api.Session = .{ .live = undefined };
    var context: server.Context = .{ .session = &session, .scratch = &scratch };
    const profile = try board_lib.profile.parse(custom);
    context.board_profile = &profile;

    const outcome = parts.boardParts(&context, .{ .core = .cpu0 });
    const given = switch (outcome) {
        .ok => |given| given,
        .err => return error.Refused,
    };
    const panel = profile.panel orelse return error.NoPanel;
    try std.testing.expectEqualStrings(panel.name, given.panel);
    try std.testing.expectEqual(panel.width, given.panel_width);
    try std.testing.expectEqual(panel.height, given.panel_height);
    try std.testing.expectEqualStrings("TEST LED", given.led_names);
    try std.testing.expectEqualStrings("SW9", given.switch_names);
    try std.testing.expectEqual(@as(usize, 2), given.led_colors.len);
}

test "a session without a chosen profile keeps the built-in default" {
    var scratch: [proto.max_payload]u8 = undefined;
    var session: api.Session = .{ .live = undefined };
    var context: server.Context = .{ .session = &session, .scratch = &scratch };

    const outcome = parts.boardParts(&context, .{ .core = .cpu0 });
    const given = switch (outcome) {
        .ok => |given| given,
        .err => return error.Refused,
    };
    const profile = try board_lib.profile.parse(board_lib.profile.ek_ra8d2);
    const panel = profile.panel orelse return error.NoPanel;
    try std.testing.expectEqualStrings(panel.name, given.panel);
    try std.testing.expectEqualStrings("LED1 BLUE\nLED2 GREEN\nLED3 RED", given.led_names);
}
