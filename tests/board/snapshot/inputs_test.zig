//! Reachable Script arithmetic at restored board time.
const std = @import("std");
const ra8 = @import("ra8");
const valid = ra8.board.snapshot.board.inputs.valid;
test "snapshot script validates pending ordering and interpolation arithmetic" {
    var script: ra8.components.input_script.Script = .{};
    try script.parse("at 1s swipe 0 0 65535 65535 2s\nat 4s longpress 1 1 1s");
    try std.testing.expect(valid(script, 0));
    script.events[1].at_ns = 0;
    try std.testing.expect(!valid(script, 0));
    script.events[1].at_ns = 4_000_000_000;
    script.events[0].event.swipe.duration_ns = std.math.maxInt(u64);
    try std.testing.expect(!valid(script, 0));
}
test "snapshot script validates active phases and restored board time" {
    var script: ra8.components.input_script.Script = .{};
    try script.parse("at 1s swipe 0 0 1 1 1s");
    var panel: ra8.components.gt911.Panel = .{};
    var input: ra8.components.touch_input.Input = .{};
    var pins = ra8.chip.periph.gpio.Gpio.init();
    script.dispatch(1_000_000_000, &panel, &pins, &input);
    try std.testing.expect(valid(script, 1_000_000_000));
    try std.testing.expect(!valid(script, 999_999_999));
    script.active.?.swipe.next = 0;
    try std.testing.expect(!valid(script, 1_000_000_000));
    script = .{};
    try script.parse("at 1ms button power");
    script.dispatch(1_000_000_000, &panel, &pins, &input);
    try std.testing.expect(valid(script, 1_000_000_000));
}
