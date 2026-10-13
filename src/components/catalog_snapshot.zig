//! Closed catalog payloads. Addresses, allocators and callbacks are wiring.
const std = @import("std");
const chip = @import("ra8_chip");
const fields = @import("ra8_snapshot").fields;
const catalog = @import("catalog.zig");
const parts = @import("parts.zig");
const endpoint = @import("endpoint.zig");
const Imu = @import("imu_lsm6dso/lsm6dso.zig").Imu;
const Gauge = @import("gauge_max17048/max17048.zig").Gauge;
const Panel = @import("eink_it8951/panel.zig").Panel;
const Modem = @import("modem_at/modem.zig").Modem;
const C6 = @import("esp32c6_hosted/hosted.zig").C6;
const Button = @import("button/button.zig").Button;
const Led = @import("led/led.zig").Led;
const panel_snapshot = @import("eink_it8951/snapshot.zig");
const c6_snapshot = @import("esp32c6_hosted/snapshot.zig");
const modem_snapshot = @import("modem_at/snapshot.zig");

pub const Tag = enum { imu, gauge, panel, modem, c6, button, led };
pub const names = .{ parts.imu_name, parts.gauge_name, parts.panel_name, parts.modem_name, parts.c6_name, parts.button_name, parts.led_name };

pub fn name(tag: Tag) []const u8 {
    return switch (tag) {
        inline else => |one| names[@backingInt(one)],
    };
}

pub fn ofModel(model: *const catalog.Model) !Tag {
    inline for (std.meta.tags(Tag)) |tag| if (model == parts.all.find(name(tag)).?) return tag;
    return error.UnsupportedAttachment;
}

pub fn cast(comptime T: type, state: *anyopaque) *T {
    return @ptrCast(@alignCast(state));
}

/// Each model's own state type, in `Tag` order.
const states = .{ Imu, Gauge, Panel, Modem, C6, Button, Led };

/// A model binds this to hand back its callbacks. Only its address is taken.
fn Probe(comptime State: type) type {
    return struct {
        var state: State = undefined;
    };
}

/// Identify a known factory by its full device callback shape, not its name.
/// `device`'s context may be any foreign pointer, so it is never cast here.
pub fn identify(device: catalog.Device, at: endpoint.Endpoint) ?Tag {
    inline for (states, 0..) |State, index| {
        const tag: Tag = @fromBackingInt(index);
        const model = parts.all.find(name(tag)).?;
        if (model.kind == at.kind()) {
            const bound = model.bindFn(&Probe(State).state, at);
            if (sameCallbacks(device, bound)) return tag;
        }
    }
    return null;
}

pub fn kindOf(device: catalog.Device) endpoint.Kind {
    return switch (device) {
        .i2c => .i2c,
        .spi => .spi,
        .uart => .uart,
        .gpio => .gpio,
    };
}

pub fn context(device: catalog.Device) *anyopaque {
    return switch (device) {
        inline else => |part| part.context,
    };
}

pub fn sameCallbacks(a: catalog.Device, b: catalog.Device) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .i2c => |p| p.writeFn == b.i2c.writeFn and p.readFn == b.i2c.readFn and p.stopFn == b.i2c.stopFn and p.ackFn == b.i2c.ackFn and p.stretchFn == b.i2c.stretchFn,
        .spi => |p| p.exchangeFn == b.spi.exchangeFn,
        .uart => |p| p.feedFn == b.uart.feedFn and p.connectFn == b.uart.connectFn and p.tickFn == b.uart.tickFn and p.spi_only == b.uart.spi_only,
        .gpio => |p| p.connectFn == b.gpio.connectFn and p.heardFn == b.gpio.heardFn,
    };
}

pub fn writePayload(writer: *std.Io.Writer, tag: Tag, state: *anyopaque) !void {
    switch (tag) {
        .imu => try fields.write(writer, cast(Imu, state).*),
        .gauge => try fields.write(writer, cast(Gauge, state).*),
        .panel => try panel_snapshot.writePayload(writer, cast(Panel, state).*),
        .modem => try modem_snapshot.writePayload(writer, cast(Modem, state)),
        .c6 => try c6_snapshot.writePayload(writer, cast(C6, state)),
        .button => {
            const button = cast(Button, state);
            try fields.write(writer, button.pressed);
            const link: ?ButtonLink = if (button.link) |held| .{ .port = held.port, .pin = held.pin } else null;
            try fields.write(writer, link);
        },
        .led => try fields.write(writer, cast(Led, state).*),
    }
}

const ButtonLink = struct { port: u8, pin: u4 };

pub fn readPayload(tag: Tag, state: *anyopaque, pins: *chip.periph.gpio.Gpio, cursor: *fields.Cursor) !void {
    switch (tag) {
        .imu => {
            const value = try fields.read(Imu, cursor);
            if (value.pointer >= value.registers.len) return error.BadValue;
            cast(Imu, state).* = value;
        },
        .gauge => {
            const value = try fields.read(Gauge, cursor);
            if ((value.pointer > value.registers.len - 2 and value.pointer != 0xfe) or value.battery.soc_pct > 100) return error.BadValue;
            cast(Gauge, state).* = value;
        },
        .panel => try panel_snapshot.readPayload(cast(Panel, state), cursor),
        .modem => try modem_snapshot.readPayload(cast(Modem, state), cursor),
        .c6 => try c6_snapshot.readPayload(cast(C6, state), cursor),
        .button => {
            const button = cast(Button, state);
            button.pressed = try fields.read(bool, cursor);
            const link = try fields.read(?ButtonLink, cursor);
            if (link) |held| {
                if (held.port >= chip.periph.gpio.port_count) return error.BadValue;
                button.link = .{ .pins = pins, .port = held.port, .pin = held.pin };
            } else button.link = null;
        },
        .led => cast(Led, state).* = try fields.read(Led, cursor),
    }
    if (!cursor.done()) return error.BadValue;
}
