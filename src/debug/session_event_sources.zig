//! Engine-thread source adapters for session events (RA8EMU-192).
const stream_mod = @import("session_event_stream.zig");
const sci = @import("../periph/sci/sci.zig");
const gpio = @import("../periph/gpio/gpio.zig");
const TimeBase = @import("../periph/time/timebase.zig").TimeBase;
const reset = @import("../periph/reset.zig");
const BoardEventSink = @import("../board/event_sink.zig").EventSink;

pub const Core = stream_mod.Core;
pub const Event = stream_mod.Event;
const Stream = stream_mod.Stream;

const Context = struct { sources: *Sources, core: Core };

pub const Sources = struct {
    stream: ?*Stream = null,
    time_base: ?*const TimeBase = null,
    uart_contexts: [2]Context = undefined,
    gpio_contexts: [2]Context = undefined,
    reset_contexts: [2]Context = undefined,
    gpio_levels: [2][gpio.port_count]u16 = [_][gpio.port_count]u16{[_]u16{0} ** gpio.port_count} ** 2,
    led_levels: [2][gpio.led_count]bool = [_][gpio.led_count]bool{[_]bool{false} ** gpio.led_count} ** 2,

    pub fn bind(self: *Sources, stream: *Stream, time_base: *const TimeBase) void {
        self.stream = stream;
        self.time_base = time_base;
    }

    pub fn uartTap(self: *Sources, core: Core) sci.Tap {
        const id = @intFromEnum(core);
        self.uart_contexts[id] = .{ .sources = self, .core = core };
        return .{ .ctx = &self.uart_contexts[id], .sent = uartSent };
    }

    pub fn gpioTap(self: *Sources, core: Core) gpio.Gpio.EventTap {
        const id = @intFromEnum(core);
        self.gpio_contexts[id] = .{ .sources = self, .core = core };
        return .{ .context = &self.gpio_contexts[id], .changedFn = gpioChanged };
    }

    pub fn boardEventSink(self: *Sources, core: Core) BoardEventSink {
        const id = @intFromEnum(core);
        self.reset_contexts[id] = .{ .sources = self, .core = core };
        return .{ .context = &self.reset_contexts[id], .resetFn = resetOccurred };
    }

    pub fn publish(self: *Sources, event: Event) void {
        var stamped = event;
        stamped.virtual_ns = if (self.time_base) |clock| clock.now() else 0;
        if (self.stream) |stream| stream.publish(stamped);
    }

    fn uartSent(context: *anyopaque, channel: usize, byte: u8) void {
        const source: *Context = @ptrCast(@alignCast(context));
        source.sources.publish(.{ .core = source.core, .kind = .uart_byte, .payload = .{ .uart = .{ .channel = @intCast(channel), .byte = byte } } });
    }

    fn gpioChanged(context: *anyopaque, port: u8, levels: u16) void {
        const source: *Context = @ptrCast(@alignCast(context));
        const core_index = @intFromEnum(source.core);
        const changed = source.sources.gpio_levels[core_index][port] ^ levels;
        source.sources.gpio_levels[core_index][port] = levels;
        if (changed != 0) source.sources.publish(.{ .core = source.core, .kind = .gpio_changed, .payload = .{ .gpio = .{ .port = port, .changed = changed, .levels = levels } } });
        for (gpio.leds, 0..) |led, index| {
            if (led.port != port or changed & (@as(u16, 1) << led.pin) == 0) continue;
            const high = levels & (@as(u16, 1) << led.pin) != 0;
            source.sources.led_levels[core_index][index] = high;
            source.sources.publish(.{ .core = source.core, .kind = .led_changed, .payload = .{ .led = .{ .index = @intCast(index), .level = high } } });
        }
    }

    fn resetOccurred(context: *anyopaque, cause: reset.Source, at_ns: u64) void {
        const source: *Context = @ptrCast(@alignCast(context));
        const reset_kind: @FieldType(Event.Payload, "reset") = switch (cause) {
            .software => .software,
            .watchdog => .watchdog,
            .iwdt => .iwdt,
        };
        if (cause == .watchdog) source.sources.publish(.{ .core = source.core, .virtual_ns = at_ns, .kind = .watchdog, .payload = .{ .watchdog = .wdt } });
        if (cause == .iwdt) source.sources.publish(.{ .core = source.core, .virtual_ns = at_ns, .kind = .watchdog, .payload = .{ .watchdog = .iwdt } });
        source.sources.publish(.{ .core = source.core, .virtual_ns = at_ns, .kind = .reset, .payload = .{ .reset = reset_kind } });
    }
};
