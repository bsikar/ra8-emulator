const std = @import("std");
const script = @import("ra8").components.input_script;
const gt911 = @import("ra8").components.gt911;
const gpio = @import("ra8").chip.periph.gpio;
const host = @import("ra8").components.touch_input;
const switches = @import("ra8").board.switches;
const sw1 = switches.user[0];

test "timed tap dispatches when virtual time reaches it" {
    var events = script.Script{};
    try events.parse("at 2s tap 300 400\n");
    var panel = gt911.Panel{};
    var pins = gpio.Gpio.init();
    var input = host.Input{};
    events.dispatch(100, &panel, &pins, &input);
    try std.testing.expectEqual(@as(usize, 0), panel.queued_len);
    events.dispatch(2_000_000_100, &panel, &pins, &input);
    try std.testing.expectEqual(@as(usize, 1), panel.queued_len);
    try std.testing.expectEqual(gt911.Contact{ .x = 300, .y = 400 }, firmwareReport(&panel).?);
    try std.testing.expectEqual(@as(u32, 1), panel.reported);
}

test "swipe emits intermediate panel reports over its duration" {
    var events = script.Script{};
    try events.parse("at 0s swipe 900 700 100 700 250ms\n");
    var panel = gt911.Panel{};
    var pins = gpio.Gpio.init();
    var input = host.Input{};
    events.dispatch(0, &panel, &pins, &input);
    events.dispatch(50_000_000, &panel, &pins, &input);
    try std.testing.expectEqual(gt911.Contact{ .x = 740, .y = 700 }, panel.queued[1]);
    events.dispatch(100_000_000, &panel, &pins, &input);
    events.dispatch(150_000_000, &panel, &pins, &input);
    events.dispatch(200_000_000, &panel, &pins, &input);
    events.dispatch(250_000_000, &panel, &pins, &input);
    try std.testing.expectEqual(gt911.Contact{ .x = 100, .y = 700 }, panel.queued[5]);
    var last: ?gt911.Contact = null;
    while (firmwareReport(&panel)) |point| last = point;
    try std.testing.expectEqual(gt911.Contact{ .x = 100, .y = 700 }, last.?);
    try std.testing.expectEqual(@as(u32, 6), panel.reported);
}

test "longpress repeats contact reports until the release time" {
    var events = script.Script{};
    try events.parse("at 0s longpress 500 500 150ms\n");
    var panel = gt911.Panel{};
    var pins = gpio.Gpio.init();
    var input = host.Input{};
    events.dispatch(0, &panel, &pins, &input);
    events.dispatch(50_000_000, &panel, &pins, &input);
    events.dispatch(100_000_000, &panel, &pins, &input);
    try std.testing.expectEqual(@as(usize, 3), panel.queued_len);
    events.dispatch(150_000_000, &panel, &pins, &input);
    try std.testing.expectEqual(@as(usize, 3), panel.queued_len);
    while (firmwareReport(&panel)) |_| {}
    try std.testing.expectEqual(@as(u32, 3), panel.reported);
    try std.testing.expectEqual(@as(u32, 3), panel.acked);
}

test "power button maps to active-low SW1" {
    var events = script.Script{};
    try events.parse("at 0s button power\n");
    var panel = gt911.Panel{};
    var pins = switches.pulled();
    var input = host.Input{ .switches = &switches.user };
    events.dispatch(0, &panel, &pins, &input);
    try std.testing.expect(!pins.pinLevel(sw1.port, sw1.pin));
    events.dispatch(100_000_000, &panel, &pins, &input);
    try std.testing.expect(pins.pinLevel(sw1.port, sw1.pin));
}

test "script rejects out-of-order event times" {
    var events = script.Script{};
    try std.testing.expectError(error.OutOfOrder, events.parse("at 2s tap 3 4\nat 1s tap 5 6\n"));
}

fn firmwareReport(panel: *gt911.Panel) ?gt911.Contact {
    var status_byte: [1]u8 = undefined;
    panel.pointer = gt911.reg.status;
    _ = panel.read(&status_byte);
    if (status_byte[0] & gt911.status.ready == 0) return null;
    var record: [gt911.record.bytes]u8 = undefined;
    panel.pointer = gt911.reg.point0;
    _ = panel.read(&record);
    panel.pointer = gt911.reg.status;
    panel.taken = gt911.pointer_bytes;
    panel.write(0);
    return .{ .x = @as(u16, record[2]) << 8 | record[1], .y = @as(u16, record[4]) << 8 | record[3] };
}

test "event bodies encode to fixed little-endian bytes" {
    var buf: [script.max_body_len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    try script.encodeBody(&writer, .{ .tap = .{ .x = 0x1234, .y = 0x5678 } });
    try std.testing.expectEqualSlices(u8, &.{ 1, 0x34, 0x12, 0x78, 0x56 }, writer.buffered());

    writer = .fixed(&buf);
    try script.encodeBody(&writer, .{ .button = .{ .down = true, .button_id = .sw2 } });
    try std.testing.expectEqualSlices(u8, &.{ 4, 1, 1 }, writer.buffered());

    writer = .fixed(&buf);
    try script.encodeBody(&writer, .{ .swipe = .{ .from = .{ .x = 1, .y = 2 }, .to = .{ .x = 3, .y = 4 }, .duration_ns = 0xAABBCCDD11223344 } });
    try std.testing.expectEqualSlices(u8, &.{
        2,    1,    0x00, 2,    0x00, 3,    0x00, 4,    0x00,
        0x44, 0x33, 0x22, 0x11, 0xDD, 0xCC, 0xBB, 0xAA,
    }, writer.buffered());

    writer = .fixed(&buf);
    try script.encodeBody(&writer, .{ .longpress = .{ .point = .{ .x = 9, .y = 8 }, .duration_ns = 1 } });
    try std.testing.expectEqualSlices(u8, &.{ 3, 9, 0x00, 8, 0x00, 1, 0, 0, 0, 0, 0, 0, 0 }, writer.buffered());
}

const Landing = script.Script.Landing;

const LandingCapture = struct {
    var seen: [8]struct { tag: u8, at_ns: u64 } = undefined;
    var seen_len: usize = 0;
    fn notify(context: *anyopaque, event: script.Event, at_ns: u64) void {
        _ = context;
        const tag: u8 = switch (event) {
            .tap => 1,
            .swipe => 2,
            .longpress => 3,
            .button => 4,
        };
        seen[seen_len] = .{ .tag = tag, .at_ns = at_ns };
        seen_len += 1;
    }
};

test "dispatch reports each queued event to the landing observer" {
    var events = script.Script{};
    try events.parse("at 1s tap 3 4\nat 2s button sw2\n");
    var panel = gt911.Panel{};
    var pins = gpio.Gpio{};
    var input = host.Input{};
    const landing = Landing{ .context = undefined, .notify = LandingCapture.notify };
    events.dispatchObserved(3_000_000_000, &panel, &pins, &input, &landing);
    try std.testing.expectEqual(@as(usize, 2), LandingCapture.seen_len);
    try std.testing.expectEqual(@as(u64, 1_000_000_000), LandingCapture.seen[0].at_ns);
    try std.testing.expectEqual(@as(u8, 1), LandingCapture.seen[0].tag);
    try std.testing.expectEqual(@as(u64, 2_000_000_000), LandingCapture.seen[1].at_ns);
    try std.testing.expectEqual(@as(u8, 4), LandingCapture.seen[1].tag);
}
