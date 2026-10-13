//! Node identities and guest payloads for the supported attachment graph.
const std = @import("std");
const components = @import("ra8_components");
const chip = @import("ra8_chip");
const fields = @import("ra8_board").snapshot.run.fields;
const catalog = components.catalog;
const codec = components.catalog_snapshot;
const fault = components.fault;
const Endpoint = components.endpoint.Endpoint;
const Board = @import("ra8_board").board.Board;
const floating = @import("plug.zig").floating;

pub const limit = 512;
pub const Builtin = enum { expander, sensor, touch, imu, gauge, panel, modem, c6, sd };
pub const Kind = union(enum) { builtin: Builtin, part: codec.Tag, i2c_fault, spi_fault, uart_fault, floating };
pub const Node = struct {
    kind: Kind,
    at: Endpoint,
    device: catalog.Device,
    inner: ?u16 = null,
};

pub fn builtin(board: *Board, which: Builtin) catalog.Device {
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

pub fn classify(board: *Board, device: catalog.Device, at: Endpoint) !Kind {
    inline for (std.meta.tags(Builtin)) |tag| {
        const bound = builtin(board, tag);
        if (codec.context(device) == codec.context(bound) and codec.sameCallbacks(device, bound)) return .{ .builtin = tag };
    }
    switch (device) {
        .i2c => {
            var probe: fault.I2c = .{ .inner = device.i2c };
            if (codec.sameCallbacks(device, .{ .i2c = probe.device() })) {
                const wrapper = codec.cast(fault.I2c, codec.context(device));
                if (wrapper.clock != null and wrapper.clock != &board.time.base) return error.UnsupportedAttachment;
                return .i2c_fault;
            }
        },
        .spi => {
            if (floating.holds(device.spi) and codec.sameCallbacks(device, .{ .spi = floating.device })) return .floating;
            var probe = fault.lines.Spi.wrap(device.spi);
            if (codec.sameCallbacks(device, .{ .spi = probe.device() })) return .spi_fault;
        },
        .uart => {
            var probe = fault.lines.Uart.wrap(device.uart);
            if (codec.sameCallbacks(device, .{ .uart = probe.device() })) return .uart_fault;
        },
        .gpio => {},
    }
    return .{ .part = codec.identify(device, at) orelse return error.UnsupportedAttachment };
}

pub fn innerOf(node: Node) ?catalog.Device {
    return switch (node.kind) {
        .i2c_fault => .{ .i2c = codec.cast(fault.I2c, codec.context(node.device)).inner },
        .spi_fault => .{ .spi = codec.cast(fault.lines.Spi, codec.context(node.device)).inner },
        .uart_fault => .{ .uart = codec.cast(fault.lines.Uart, codec.context(node.device)).inner },
        else => null,
    };
}

pub fn writePayload(node: Node, writer: *std.Io.Writer) !void {
    const state = codec.context(node.device);
    switch (node.kind) {
        .part => |tag| try codec.writePayload(writer, tag, state),
        .i2c_fault => {
            const wrapper = codec.cast(fault.I2c, state);
            try fields.write(writer, wrapper.clock != null);
            try fields.writeExcept(writer, wrapper.*, .{ "inner", "clock" });
        },
        .spi_fault => try fields.writeExcept(writer, codec.cast(fault.lines.Spi, state).*, .{"inner"}),
        .uart_fault => try fields.writeExcept(writer, codec.cast(fault.lines.Uart, state).*, .{ "inner", "reply" }),
        .builtin, .floating => {},
    }
}

pub fn readNode(allocator: std.mem.Allocator, board: *Board, kind: Kind, at: Endpoint, inner: ?catalog.Device, cursor: *fields.Cursor) !Node {
    const device: catalog.Device = switch (kind) {
        .builtin => |which| builtin(board, which),
        .floating => .{ .spi = floating.device },
        .part => |tag| blk: {
            const made = try components.parts.all.make(allocator, codec.name(tag), at);
            // Panel planes use the same detached arena, not the host heap.
            if (tag == .panel) codec.cast(components.eink.Panel, made.state).planes.allocator = allocator;
            try codec.readPayload(tag, made.state, &board.pins, cursor);
            break :blk made.device;
        },
        .i2c_fault => blk: {
            if (inner == null or inner.? != .i2c) return error.BadValue;
            const wrapper = try allocator.create(fault.I2c);
            const timed = try fields.read(bool, cursor);
            wrapper.* = fault.I2c.wrap(inner.?.i2c);
            wrapper.clock = if (timed) &board.time.base else null;
            try fields.readOver(cursor, wrapper, .{ "inner", "clock" });
            if (wrapper.mode == .nack_every and wrapper.mode.nack_every == 0) return error.BadValue;
            break :blk .{ .i2c = wrapper.device() };
        },
        .spi_fault => blk: {
            if (inner == null or inner.? != .spi) return error.BadValue;
            const wrapper = try allocator.create(fault.lines.Spi);
            wrapper.* = fault.lines.Spi.wrap(inner.?.spi);
            try fields.readOver(cursor, wrapper, .{"inner"});
            break :blk .{ .spi = wrapper.device() };
        },
        .uart_fault => blk: {
            if (inner == null or inner.? != .uart) return error.BadValue;
            const wrapper = try allocator.create(fault.lines.Uart);
            wrapper.* = fault.lines.Uart.wrap(inner.?.uart);
            @memset(&wrapper.reply, 0);
            try fields.readOver(cursor, wrapper, .{ "inner", "reply" });
            break :blk .{ .uart = wrapper.device() };
        },
    };
    if (!cursor.done() or codec.kindOf(device) != at.kind()) return error.BadValue;
    if (device == .i2c and device.i2c.address != at.i2c.address) return error.BadValue;
    return .{ .kind = kind, .at = at, .device = device };
}

pub fn validEndpoint(at: Endpoint) bool {
    return switch (at) {
        .i2c => |where| !chip.periph.riic.bus.reserved.holds(where.address),
        .spi => true,
        .uart => |where| where.channel < components.endpoint.limits.sci_channels,
        .gpio => |where| where.port < components.endpoint.limits.ports,
    };
}
