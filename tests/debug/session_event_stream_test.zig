//! Bounded session event stream tests (RA8EMU-192).
const std = @import("std");
const stream_api = @import("ra8").core.session_event_stream;
const api = @import("ra8").core.session_api;
const sci = @import("ra8").periph.sci;
const gpio = @import("ra8").periph.gpio;

test "slow subscriber is bounded, reports loss and coalesces frames" {
    var stream: stream_api.Stream = .{};
    const id = stream.subscribe().?;
    for (0..stream_api.capacity + 10) |i| stream.publish(.{
        .core = .cpu0,
        .virtual_ns = i,
        .kind = if (i % 2 == 0) .lcd_frame else .uart_byte,
        .payload = if (i % 2 == 0)
            .{ .frame = .{ .width = 2, .height = 2, .generation = i, .dirty = .{ .x = 0, .y = 0, .width = 2, .height = 2 } } }
        else
            .{ .uart = .{ .channel = 8, .byte = @intCast(i) } },
    });
    var out: [stream_api.capacity]stream_api.Event = undefined;
    const result = stream.read(id, &out).?;
    try std.testing.expect(result.count > 0 and result.count <= stream_api.capacity);
    try std.testing.expect(result.dropped > 0);
}

test "each hardware event kind carries a virtual timestamp and source data" {
    var stream: stream_api.Stream = .{};
    const id = stream.subscribe().?;
    const kinds = [_]stream_api.Event.Kind{ .uart_byte, .gpio_changed, .led_changed, .lcd_frame, .fault, .reset, .watchdog };
    for (kinds, 0..) |kind, i| stream.publish(.{
        .core = .cpu1,
        .virtual_ns = 500 + i,
        .kind = kind,
        .payload = switch (kind) {
            .uart_byte => .{ .uart = .{ .channel = 8, .byte = 'A' } },
            .gpio_changed => .{ .gpio = .{ .port = 6, .changed = 1, .levels = 1 } },
            .led_changed => .{ .led = .{ .index = 0, .level = true } },
            .lcd_frame => .{ .frame = .{ .width = 2, .height = 1, .generation = 3, .dirty = .{ .x = 0, .y = 0, .width = 2, .height = 1 } } },
            .fault => .{ .fault = .{ .cause = 0x8200, .address = 0x1234 } },
            .reset => .{ .reset = .watchdog },
            .watchdog => .{ .watchdog = .wdt },
            else => .none,
        },
    });
    var events: [kinds.len]stream_api.Event = undefined;
    const result = stream.read(id, &events).?;
    try std.testing.expectEqual(kinds.len, result.count);
    for (events[0..result.count], kinds, 0..) |event, kind, i| {
        try std.testing.expectEqual(kind, event.kind);
        try std.testing.expectEqual(@as(u64, 500 + i), event.virtual_ns);
        try std.testing.expectEqual(stream_api.Core.cpu1, event.core);
    }
}

test "SCI, GPIO and LED taps publish timestamped source events" {
    var base: @import("ra8").periph.clocks.timebase.TimeBase = .{};
    var session: api.Session = .{ .live = undefined };
    session.attachTimeBase(&base);
    const subscription = session.event_stream.subscribe().?;
    var serial = sci.Sci.init();
    serial.tap = session.event_sources.uartTap(.cpu1);
    serial.write(sci.win_base + 8 * sci.stride + sci.off_ccr0, 4, sci.ccr0.te);
    serial.write(sci.win_base + 8 * sci.stride + sci.off_tdr, 1, 'Z');
    base.advance(17);
    var pins = gpio.Gpio.init();
    pins.observeEvents(session.event_sources.gpioTap(.cpu1));
    pins.applyWrite(gpio.regAddress(6, gpio.pcntr1), 4, (@as(u32, 1) << 16) | 1);
    var events: [4]stream_api.Event = undefined;
    const got = session.event_stream.read(subscription, &events).?;
    try std.testing.expectEqual(@as(usize, 3), got.count);
    try std.testing.expectEqual(stream_api.Event.Kind.uart_byte, events[0].kind);
    try std.testing.expectEqual(@as(u64, 0), events[0].virtual_ns);
    try std.testing.expectEqual(@as(u8, 'Z'), events[0].payload.uart.byte);
    try std.testing.expectEqual(@as(u64, 17), events[1].virtual_ns);
    try std.testing.expectEqual(stream_api.Event.Kind.gpio_changed, events[1].kind);
    try std.testing.expectEqual(stream_api.Event.Kind.led_changed, events[2].kind);
}
