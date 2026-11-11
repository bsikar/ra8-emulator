//! Direct non-circular inspection of Board attachment topology, plugged
//! catalog devices, and I2C/SPI/UART fault wrappers without production
//! attachment serializers.
const std = @import("std");
const ra8 = @import("ra8");
const hash = @import("common_hash.zig");
const board_oracle = @import("common_board_oracle.zig");

const Digest = hash.Digest;
const Hasher = hash.Hasher;
const Board = ra8.board.board.Board;
const Binding = ra8.session.board.state.attachments.Binding;
const components = ra8.components;
const catalog = components.catalog;
const Endpoint = components.endpoint.Endpoint;
const fault = components.fault;
const floating = ra8.session.board.plug.floating;

const Builtin = enum(u8) { expander, sensor, touch, imu, gauge, panel, modem, c6, sd };
const PartTag = enum(u8) { imu, gauge, panel, modem, c6, button, led };

const part_names = .{
    components.parts.imu_name,
    components.parts.gauge_name,
    components.parts.panel_name,
    components.parts.modem_name,
    components.parts.c6_name,
    components.parts.button_name,
    components.parts.led_name,
};

const part_states = .{
    components.lsm6dso.Imu,
    components.max17048.Gauge,
    components.eink.Panel,
    components.modem_at.Modem,
    components.esp_hosted.C6,
    components.button.Button,
    components.led.Led,
};

fn Probe(comptime S: type) type {
    return struct {
        var instance: S = undefined;
    };
}

fn devContext(dev: catalog.Device) *anyopaque {
    return switch (dev) {
        inline else => |d| d.context,
    };
}

fn sameCallbacks(a: catalog.Device, b: catalog.Device) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .i2c => |p| p.writeFn == b.i2c.writeFn and p.readFn == b.i2c.readFn and p.stopFn == b.i2c.stopFn and p.ackFn == b.i2c.ackFn and p.stretchFn == b.i2c.stretchFn,
        .spi => |p| p.exchangeFn == b.spi.exchangeFn,
        .uart => |p| p.feedFn == b.uart.feedFn and p.connectFn == b.uart.connectFn and p.tickFn == b.uart.tickFn and p.spi_only == b.uart.spi_only,
        .gpio => |p| p.connectFn == b.gpio.connectFn and p.heardFn == b.gpio.heardFn,
    };
}

fn builtinDevice(board: *Board, which: Builtin) catalog.Device {
    return switch (which) {
        .expander => .{ .i2c = board.wire.expander.device() },
        .sensor => .{ .i2c = board.wire.sensor.device() },
        .touch => .{ .i2c = board.wire.panel.device() },
        .imu => .{ .i2c = board.wire.imu.device() },
        .gauge => .{ .i2c = board.wire.gauge.device() },
        .panel => .{ .spi = board.panel.device() },
        .modem => .{ .uart = board.modem.device() },
        .c6 => .{ .uart = board.c6.device() },
        .sd => .{ .uart = board.sd_line.device() },
    };
}

fn matchBuiltin(board: *Board, dev: catalog.Device) ?Builtin {
    inline for (std.meta.tags(Builtin)) |tag| {
        const bound = builtinDevice(board, tag);
        if (devContext(dev) == devContext(bound) and sameCallbacks(dev, bound)) return tag;
    }
    return null;
}

fn matchPart(dev: catalog.Device, at: Endpoint) ?PartTag {
    inline for (part_states, 0..) |State, idx| {
        const tag: PartTag = @fromBackingInt(idx);
        const model = components.parts.all.find(part_names[idx]).?;
        if (model.kind == at.kind()) {
            const bound = model.bindFn(&Probe(State).instance, at);
            if (sameCallbacks(dev, bound)) return tag;
        }
    }
    return null;
}

fn hashPartState(h: *Hasher, tag: PartTag, ctx: *anyopaque) void {
    h.auto(tag);
    switch (tag) {
        .imu => h.auto(@as(*const components.lsm6dso.Imu, @ptrCast(@alignCast(ctx))).*),
        .gauge => h.auto(@as(*const components.max17048.Gauge, @ptrCast(@alignCast(ctx))).*),
        .panel => board_oracle.hashPanel(h, @ptrCast(@alignCast(ctx))),
        .modem => board_oracle.hashModem(h, @ptrCast(@alignCast(ctx))),
        .c6 => board_oracle.hashC6(h, @ptrCast(@alignCast(ctx))),
        .button => {
            const btn: *const components.button.Button = @ptrCast(@alignCast(ctx));
            h.boolean(btn.pressed);
            h.boolean(btn.link != null);
            if (btn.link) |lnk| {
                h.int(lnk.port);
                h.int(lnk.pin);
            }
        },
        .led => h.auto(@as(*const components.led.Led, @ptrCast(@alignCast(ctx))).*),
    }
}

fn hashDeviceChain(h: *Hasher, board: *Board, dev: catalog.Device, at: Endpoint, depth: u8) void {
    h.auto(at);
    if (depth > 8) {
        h.byte(0xfe);
        return;
    }
    if (matchBuiltin(board, dev)) |which| {
        h.byte(1);
        h.auto(which);
        return;
    }
    const ctx = devContext(dev);
    switch (dev) {
        .i2c => |d| {
            var probe: fault.I2c = .{ .inner = d };
            if (sameCallbacks(dev, .{ .i2c = probe.device() })) {
                const wrap: *const fault.I2c = @ptrCast(@alignCast(ctx));
                h.byte(2);
                h.boolean(wrap.clock != null);
                h.autoExcept(wrap.*, .{ "inner", "clock" });
                hashDeviceChain(h, board, .{ .i2c = wrap.inner }, at, depth + 1);
                return;
            }
        },
        .spi => |d| {
            if (floating.holds(d) and sameCallbacks(dev, .{ .spi = floating.device })) {
                h.byte(3);
                return;
            }
            var probe = fault.lines.Spi.wrap(d);
            if (sameCallbacks(dev, .{ .spi = probe.device() })) {
                const wrap: *const fault.lines.Spi = @ptrCast(@alignCast(ctx));
                h.byte(4);
                h.autoExcept(wrap.*, .{"inner"});
                hashDeviceChain(h, board, .{ .spi = wrap.inner }, at, depth + 1);
                return;
            }
        },
        .uart => |d| {
            var probe = fault.lines.Uart.wrap(d);
            if (sameCallbacks(dev, .{ .uart = probe.device() })) {
                const wrap: *const fault.lines.Uart = @ptrCast(@alignCast(ctx));
                h.byte(5);
                h.autoExcept(wrap.*, .{ "inner", "reply" });
                hashDeviceChain(h, board, .{ .uart = wrap.inner }, at, depth + 1);
                return;
            }
        },
        .gpio => {},
    }
    if (matchPart(dev, at)) |tag| {
        h.byte(6);
        hashPartState(h, tag, ctx);
    } else {
        h.byte(0xff);
    }
}

pub fn attachmentsDigest(board: *Board, binding: ?Binding) Digest {
    var h: Hasher = .{};
    const regs = [_]*@TypeOf(board.wire.controller.devices){
        &board.wire.controller.devices,
        &board.wire.touchline.devices,
    };
    for (regs, 0..) |reg, line| {
        for (reg.devices) |entry| {
            h.boolean(entry != null);
            if (entry) |part| {
                const at: Endpoint = .{ .i2c = .{ .line = @fromBackingInt(@intCast(line)), .address = part.address } };
                hashDeviceChain(&h, board, .{ .i2c = part }, at, 0);
            }
        }
    }
    for (board.spi.channels, 0..) |unit, ch| {
        h.boolean(unit.device != null);
        if (unit.device) |part| {
            var at: Endpoint = .{ .spi = .{ .channel = @intCast(ch), .select = 0 } };
            if (binding) |b| for (b.plugs.fitted[0..b.plugs.fitted_count]) |fit| {
                if (fit.at == .spi and fit.at.spi.channel == ch) at = fit.at;
            };
            hashDeviceChain(&h, board, .{ .spi = part }, at, 0);
        }
    }
    for (board.serial.channels, 0..) |unit, ch| {
        h.boolean(unit.device != null);
        if (unit.device) |part| {
            const at: Endpoint = .{ .uart = .{ .channel = @intCast(ch) } };
            hashDeviceChain(&h, board, .{ .uart = part }, at, 0);
        }
    }
    const gpio_count = @min(board.pins.wired.count, board.pins.wired.slots.len);
    h.int(@as(u8, @intCast(gpio_count)));
    for (board.pins.wired.slots[0..gpio_count]) |slot| {
        const at: Endpoint = .{ .gpio = .{ .port = @intCast(slot.port), .pin = slot.pin } };
        hashDeviceChain(&h, board, .{ .gpio = slot.device }, at, 0);
    }
    const ask_count = @min(board.asks.count, board.asks.asked.len);
    h.int(@as(u8, @intCast(ask_count)));
    for (board.asks.asked[0..ask_count]) |ask| {
        h.bytes(ask.name);
        h.auto(ask.at);
        h.auto(ask.fault);
        h.auto(ask.geometry);
    }
    h.boolean(board.asks.attached_eink != null);
    if (board.asks.attached_eink) |panel| board_oracle.hashPanel(&h, panel);
    if (binding) |b| {
        h.boolean(true);
        const fit_count = @min(b.plugs.fitted_count, b.plugs.fitted.len);
        h.int(@as(u16, @intCast(fit_count)));
        for (b.plugs.fitted[0..fit_count]) |fit| {
            h.bytes(fit.name);
            h.auto(fit.at);
        }
        for (b.plugs.panels) |p| {
            h.boolean(p != null);
            if (p) |panel| board_oracle.hashPanel(&h, panel);
        }
    } else h.boolean(false);

    h.boolean(board.pins.observer != null);
    if (board.pins.observer) |obs| {
        h.boolean(obs.context == @as(*anyopaque, &board.c6));
    }
    return h.final();
}
