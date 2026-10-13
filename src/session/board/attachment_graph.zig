//! Walk the reachable graph, including retained displaced and cleared parts.
const std = @import("std");
const components = @import("ra8_components");
const catalog = components.catalog;
const codec = components.catalog_snapshot;
const Endpoint = components.endpoint.Endpoint;
const Board = @import("ra8_board").board.Board;
const nodes = @import("attachment_nodes.zig");
const plug = @import("plug.zig");
const Faults = @import("faults/faults.zig").Faults;

pub const Graph = struct {
    nodes: [nodes.limit]nodes.Node = undefined,
    count: usize = 0,
    runtime: [256]?u16 = @splat(null),
    runtime_count: usize = 0,
    wrapped: [@import("faults/faults.zig").max_wrapped]?u16 = @splat(null),
    spi_held: [2]?u16 = @splat(null),
    uart_held: [10]?u16 = @splat(null),

    pub fn add(self: *Graph, board: *Board, device: catalog.Device, at: Endpoint, depth: usize) anyerror!u16 {
        if (!nodes.validEndpoint(at) or depth > 64) return error.UnsupportedAttachment;
        for (self.nodes[0..self.count], 0..) |node, id| {
            if (codec.context(node.device) == codec.context(device) and codec.sameCallbacks(node.device, device)) return @intCast(id);
        }
        var node: nodes.Node = .{ .kind = try nodes.classify(board, device, at), .at = at, .device = device };
        if (nodes.innerOf(node)) |inner| node.inner = try self.add(board, inner, at, depth + 1);
        if (self.count == self.nodes.len) return error.UnsupportedAttachment;
        const id = self.count;
        self.nodes[id] = node;
        self.count += 1;
        return @intCast(id);
    }

    pub fn retain(self: *Graph, board: *Board, plugs: ?*const plug.Plugs, faults: ?*const Faults) !void {
        if (plugs) |held| {
            if (held.instance_count > self.runtime.len) return error.BadValue;
            self.runtime_count = held.instance_count;
            for (held.instances[0..held.instance_count], 0..) |instance, index| {
                _ = try codec.ofModel(instance.model);
                self.runtime[index] = try self.add(board, instance.device, held.instance_endpoints[index], 0);
            }
            for (held.snapshot_owned[0..held.snapshot_owned_count], 0..) |instance, index| {
                _ = try codec.ofModel(instance.model);
                _ = try self.add(board, instance.device, held.snapshot_endpoints[index], 0);
            }
        }
        if (faults) |held| {
            for (held.wrapped, 0..) |entry, index| if (entry) |wrapper| {
                self.wrapped[index] = try self.add(board, .{ .i2c = wrapper.device() }, i2cEndpoint(board, wrapper.device()), 0);
            };
            for (held.spi_parts.held, 0..) |entry, index| if (entry) |wrapper| {
                self.spi_held[index] = try self.add(board, .{ .spi = wrapper.device() }, spiEndpoint(board, plugs, wrapper.device(), index), 0);
            };
            for (held.uart_parts.held, 0..) |entry, index| if (entry) |wrapper| {
                self.uart_held[index] = try self.add(board, .{ .uart = wrapper.device() }, .{ .uart = .{ .channel = @intCast(index) } }, 0);
            };
        }
    }
};

/// A registered wrapper carries its real line; an orphan has no live slot.
fn i2cEndpoint(board: *Board, device: @import("ra8_chip").periph.riic.bus.Device) Endpoint {
    const registries = .{ &board.wire.controller.devices, &board.wire.touchline.devices };
    inline for (registries, 0..) |registry, line| {
        for (registry.devices) |entry| if (entry) |part| {
            if (part.context == device.context) return .{ .i2c = .{ .line = @fromBackingInt(line), .address = device.address } };
        };
    }
    return endpointOf(.{ .i2c = device });
}

/// Only an active wrapper uses fitted metadata as its owned select.
fn spiEndpoint(board: *Board, plugs: ?*const plug.Plugs, device: @import("ra8_chip").periph.spi.Device, index: usize) Endpoint {
    const fallback: Endpoint = .{ .spi = .{ .channel = @intCast(index), .select = 0 } };
    const active = board.spi.channels[index].device orelse return fallback;
    if (active.context != device.context) return fallback;
    if (plugs) |held| for (held.fitted[0..held.fitted_count]) |fit| {
        if (fit.at == .spi and fit.at.spi.channel == index) return fit.at;
    };
    return fallback;
}

pub fn endpointOf(device: catalog.Device) Endpoint {
    return switch (device) {
        .i2c => |part| .{ .i2c = .{ .line = .riic, .address = part.address } },
        .spi => .{ .spi = .{ .channel = 0, .select = 0 } },
        .uart => .{ .uart = .{ .channel = 0 } },
        .gpio => .{ .gpio = .{ .port = 0, .pin = 0 } },
    };
}
