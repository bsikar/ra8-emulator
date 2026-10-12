//! Bounded session event stream tests (RA8EMU-192).
const std = @import("std");
const stream_api = @import("ra8").session.event.stream;
const api = @import("ra8").session.api;
const sci = @import("ra8").chip.periph.sci;
const gpio = @import("ra8").chip.periph.gpio;

test "a stalled subscriber cannot backpressure the producer and keeps the newest window" {
    var stream: stream_api.Stream = .{};
    const id = stream.subscribe().?;
    for (0..stream_api.capacity + 10) |i| stream.publish(.{
        .core = .cpu0,
        .virtual_ns = i,
        .kind = .uart_byte,
        .payload = .{ .uart = .{ .channel = 8, .byte = @truncate(i) } },
    });
    var out: [stream_api.capacity]stream_api.Event = undefined;
    const overflowed = stream.read(id, &out).?;
    try std.testing.expectEqual(stream_api.capacity, overflowed.count);
    try std.testing.expectEqual(@as(u64, 10), overflowed.dropped);
    try std.testing.expectEqual(@as(u64, 10), out[0].virtual_ns);
    try std.testing.expectEqual(@as(u64, stream_api.capacity + 9), out[overflowed.count - 1].virtual_ns);
    const drained = stream.read(id, &out).?;
    try std.testing.expectEqual(@as(usize, 0), drained.count);
    try std.testing.expectEqual(@as(u64, 0), drained.dropped);
}

test "frame coalescing keeps the newest frame in core and time order" {
    var stream: stream_api.Stream = .{};
    const id = stream.subscribe().?;
    stream.publish(frame(.cpu0, 1));
    stream.publish(.{ .core = .cpu0, .virtual_ns = 2, .kind = .uart_byte, .payload = .{ .uart = .{ .channel = 8, .byte = 'A' } } });
    stream.publish(frame(.cpu1, 3));
    stream.publish(frame(.cpu0, 4));
    var events: [4]stream_api.Event = undefined;
    const result = stream.read(id, &events).?;
    try std.testing.expectEqual(@as(usize, 3), result.count);
    try std.testing.expectEqual(@as(u64, 1), result.dropped);
    try std.testing.expectEqual(stream_api.Event.Kind.uart_byte, events[0].kind);
    try std.testing.expectEqual(@as(u64, 2), events[0].virtual_ns);
    try std.testing.expectEqual(stream_api.Core.cpu1, events[1].core);
    try std.testing.expectEqual(@as(u64, 3), events[1].payload.frame.generation);
    try std.testing.expectEqual(stream_api.Core.cpu0, events[2].core);
    try std.testing.expectEqual(@as(u64, 4), events[2].payload.frame.generation);
}

fn frame(core: stream_api.Core, generation: u64) stream_api.Event {
    return .{
        .core = core,
        .virtual_ns = generation,
        .kind = .lcd_frame,
        .payload = .{ .frame = .{ .width = 2, .height = 2, .generation = generation, .dirty = .{ .x = 0, .y = 0, .width = 2, .height = 2 } } },
    };
}

const ConcurrentPublish = struct {
    stream: *stream_api.Stream,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *ConcurrentPublish) void {
        for (0..10_000) |i| self.stream.publish(.{
            .core = .cpu0,
            .virtual_ns = i,
            .kind = .uart_byte,
            .payload = .{ .uart = .{ .channel = 0, .byte = @truncate(i) } },
        });
        self.done.store(true, .release);
    }
};

test "engine publication and subscriber polling share a bounded queue safely" {
    var stream: stream_api.Stream = .{};
    const id = stream.subscribe().?;
    var producer = ConcurrentPublish{ .stream = &stream };
    const thread = try std.Thread.spawn(.{}, ConcurrentPublish.run, .{&producer});
    var delivered: u64 = 0;
    var dropped: u64 = 0;
    var last: ?u64 = null;
    var events: [16]stream_api.Event = undefined;
    while (!producer.done.load(.acquire)) {
        const got = stream.read(id, &events).?;
        dropped += got.dropped;
        for (events[0..got.count]) |event| {
            if (last) |before| try std.testing.expect(event.virtual_ns > before);
            last = event.virtual_ns;
            delivered += 1;
        }
    }
    thread.join();
    while (true) {
        const got = stream.read(id, &events).?;
        dropped += got.dropped;
        for (events[0..got.count]) |event| {
            if (last) |before| try std.testing.expect(event.virtual_ns > before);
            last = event.virtual_ns;
            delivered += 1;
        }
        if (got.count == 0) break;
    }
    try std.testing.expectEqual(@as(u64, 10_000), delivered + dropped);
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
    var base: @import("ra8").chip.periph.clocks.timebase.TimeBase = .{};
    var session: api.Session = .{ .live = undefined };
    session.attachTimeBase(&base);
    const subscription = try session.subscribe();
    var serial = sci.Sci.init();
    serial.tap = session.event_sources.uartTap(.cpu1);
    serial.write(sci.win_base + 8 * sci.stride + sci.off_ccr0, 4, sci.ccr0.te);
    serial.write(sci.win_base + 8 * sci.stride + sci.off_tdr, 1, 'Z');
    base.advance(17);
    var pins = gpio.Gpio.init();
    pins.observeEvents(session.event_sources.gpioTap(&pins, .cpu1));
    pins.applyWrite(gpio.regAddress(6, gpio.pcntr1), 4, (@as(u32, 1) << 16) | 1);
    var events: [4]stream_api.Event = undefined;
    const got = session.pollEvents(subscription, &events).?;
    try std.testing.expectEqual(@as(usize, 3), got.count);
    try std.testing.expectEqual(stream_api.Event.Kind.uart_byte, events[0].kind);
    try std.testing.expectEqual(@as(u64, 0), events[0].virtual_ns);
    try std.testing.expectEqual(@as(u8, 'Z'), events[0].payload.uart.byte);
    try std.testing.expectEqual(@as(u64, 17), events[1].virtual_ns);
    try std.testing.expectEqual(stream_api.Event.Kind.gpio_changed, events[1].kind);
    try std.testing.expectEqual(stream_api.Event.Kind.led_changed, events[2].kind);
}

test "a full queue evicts telemetry first and keeps the state changes in order" {
    var stream: stream_api.Stream = .{};
    const id = stream.subscribe().?;
    for (0..stream_api.capacity) |i| stream.publish(.{
        .core = .cpu0,
        .virtual_ns = i,
        .kind = .uart_byte,
        .payload = .{ .uart = .{ .channel = 8, .byte = @truncate(i) } },
    });
    stream.publish(.{ .core = .cpu0, .kind = .fault_set, .payload = .{ .fault = .{ .cause = 3 } } });
    stream.publish(.{ .core = .cpu0, .kind = .fault_cleared });
    var out: [stream_api.capacity]stream_api.Event = undefined;
    const got = stream.read(id, &out).?;
    try std.testing.expectEqual(stream_api.capacity, got.count);
    try std.testing.expectEqual(@as(u64, 2), got.dropped);
    try std.testing.expectEqual(stream_api.Event.Kind.uart_byte, out[0].kind);
    try std.testing.expectEqual(@as(u64, 2), out[0].virtual_ns);
    try std.testing.expectEqual(stream_api.Event.Kind.fault_set, out[got.count - 2].kind);
    try std.testing.expectEqual(@as(u32, 3), out[got.count - 2].payload.fault.cause);
    try std.testing.expectEqual(stream_api.Event.Kind.fault_cleared, out[got.count - 1].kind);
}

test "a full queue that holds no telemetry drops its oldest event instead" {
    var stream: stream_api.Stream = .{};
    const id = stream.subscribe().?;
    for (0..stream_api.capacity) |i| stream.publish(.{ .core = .cpu0, .virtual_ns = i, .kind = .loaded });
    stream.publish(.{ .core = .cpu0, .virtual_ns = stream_api.capacity, .kind = .stopped });
    var out: [stream_api.capacity]stream_api.Event = undefined;
    const got = stream.read(id, &out).?;
    try std.testing.expectEqual(stream_api.capacity, got.count);
    try std.testing.expectEqual(@as(u64, 1), got.dropped);
    try std.testing.expectEqual(@as(u64, 1), out[0].virtual_ns);
    try std.testing.expectEqual(@as(u64, stream_api.capacity), out[got.count - 1].virtual_ns);
}

fn drainChurn(stream: *stream_api.Stream, id: usize, out: []stream_api.Event, seen: *usize, last: *?u64) !void {
    while (true) {
        const got = stream.read(id, out).?;
        if (got.count == 0 and got.dropped == 0) break;
        for (out[0..got.count]) |event| {
            if (last.*) |before| try std.testing.expect(event.virtual_ns > before);
            last.* = event.virtual_ns;
            if (event.kind == .breakpoint_set) seen.* += 1;
        }
    }
}

test "state changes between telemetry stay in publication order under churn" {
    var stream: stream_api.Stream = .{};
    const id = stream.subscribe().?;
    var seen: usize = 0;
    var last: ?u64 = null;
    var out: [64]stream_api.Event = undefined;
    for (0..stream_api.capacity * 3) |i| {
        if (i % 64 == 32) {
            stream.publish(.{ .core = .cpu0, .virtual_ns = i, .kind = .breakpoint_set, .address = @intCast(i) });
        } else {
            stream.publish(.{
                .core = .cpu0,
                .virtual_ns = i,
                .kind = .uart_byte,
                .payload = .{ .uart = .{ .channel = 0, .byte = @truncate(i) } },
            });
        }
        if (i % 16 == 15) try drainChurn(&stream, id, &out, &seen, &last);
    }
    try drainChurn(&stream, id, &out, &seen, &last);
    try std.testing.expectEqual(@as(usize, 6), seen);
}
