//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! Polled input: the GT911 touch panel and the SW1 user switch, which
//! stands in for a power key. Each reports once per press.

const hal = @import("hal.zig");

pub const Event = union(enum) {
    tap: struct { x: i32, y: i32 },
    power,
};

var touching = false;
var holding = false;

pub fn init() void {
    _ = hal.ra8_board_touch_open(&.{});
    _ = hal.ra8_board_sw_init(hal.switches.sw1);
}

fn touch() ?Event {
    var point: hal.TouchPoint = .{};
    var count: u8 = 0;
    if (hal.ra8_touch_read(&point, 1, &count) != hal.ok) return null;
    const down = count > 0;
    defer touching = down;
    if (!down or touching) return null;
    return .{ .tap = .{ .x = point.x, .y = point.y } };
}

fn power() ?Event {
    var state: u8 = 0;
    if (hal.ra8_board_sw_read(hal.switches.sw1, &state) != hal.ok) return null;
    const down = state == hal.switches.pressed;
    defer holding = down;
    if (!down or holding) return null;
    return .power;
}

/// The next fresh press, if there is one.
pub fn poll() ?Event {
    return touch() orelse power();
}
