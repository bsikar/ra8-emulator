//! Exact bus slots and startup metadata, with bounds and duplicate checks.
const std = @import("std");
const c = @import("ra8_components");
const fields = @import("ra8_board").snapshot.run.fields;
const Board = @import("ra8_board").board.Board;
const graph = @import("attachment_graph.zig");
const nodes = @import("attachment_nodes.zig");
const codec = c.catalog_snapshot;
const Plugs = @import("plug.zig").Plugs;
const Endpoint = c.endpoint.Endpoint;

pub const Ref = struct { id: u16, at: Endpoint };
pub const Ask = struct {
    tag: ?codec.Tag,
    at: Endpoint,
    fault: ?c.fault.spec.Mode,
    geometry: ?c.eink.wire.Geometry,
};
pub const Fitted = struct { tag: codec.Tag, at: Endpoint };
pub const Topology = struct {
    i2c: [2][4]?Ref = @splat(@splat(null)),
    spi: [2]?Ref = @splat(null),
    uart: [10]?Ref = @splat(null),
    gpio: [4]?Ref = @splat(null),
    panels: [2]?u16 = @splat(null),
    attached_panel: ?u16 = null,
    observer: ?u16 = null,
    asks: [8]Ask = undefined,
    ask_count: u8 = 0,
    fitted: [264]Fitted = undefined,
    fitted_count: u16 = 0,

    pub fn capture(board: *Board, plugs: ?*const Plugs, g: *graph.Graph) !Topology {
        var out: Topology = .{};
        const registries = [_]*@TypeOf(board.wire.controller.devices){ &board.wire.controller.devices, &board.wire.touchline.devices };
        for (registries, 0..) |registry, line| for (registry.devices, 0..) |entry, index| if (entry) |part| {
            const at: Endpoint = .{ .i2c = .{ .line = @fromBackingInt(@intCast(line)), .address = part.address } };
            out.i2c[line][index] = .{ .id = try g.add(board, .{ .i2c = part }, at, 0), .at = at };
        };
        for (board.spi.channels, 0..) |unit, index| if (unit.device) |part| {
            var at: Endpoint = .{ .spi = .{ .channel = @intCast(index), .select = 0 } };
            if (plugs) |held| for (held.fitted[0..held.fitted_count]) |fit| {
                if (fit.at == .spi and fit.at.spi.channel == index) at = fit.at;
            };
            out.spi[index] = .{ .id = try g.add(board, .{ .spi = part }, at, 0), .at = at };
        };
        for (board.serial.channels, 0..) |unit, index| if (unit.device) |part| {
            const at: Endpoint = .{ .uart = .{ .channel = @intCast(index) } };
            out.uart[index] = .{ .id = try g.add(board, .{ .uart = part }, at, 0), .at = at };
        };
        for (board.pins.wired.slots[0..board.pins.wired.count], 0..) |slot, index| {
            if (slot.port >= c.endpoint.limits.ports) return error.UnsupportedAttachment;
            const at: Endpoint = .{ .gpio = .{ .port = @intCast(slot.port), .pin = slot.pin } };
            out.gpio[index] = .{ .id = try g.add(board, .{ .gpio = slot.device }, at, 0), .at = at };
        }
        if (board.asks.count > out.asks.len) return error.BadValue;
        out.ask_count = @intCast(board.asks.count);
        for (board.asks.asked[0..board.asks.count], 0..) |ask, index| {
            const model = if (ask.name.len == 0) null else c.parts.all.find(ask.name) orelse return error.UnsupportedAttachment;
            out.asks[index] = .{ .tag = if (model) |held| try codec.ofModel(held) else null, .at = ask.at, .fault = ask.fault, .geometry = ask.geometry };
        }
        if (plugs) |held| {
            out.fitted_count = @intCast(held.fitted_count);
            for (held.fitted[0..held.fitted_count], 0..) |fitted, index| {
                out.fitted[index] = .{ .tag = try codec.ofModel(c.parts.all.find(fitted.name) orelse return error.UnsupportedAttachment), .at = fitted.at };
            }
            for (held.panels, 0..) |entry, index| if (entry) |panel| {
                out.panels[index] = try g.add(board, .{ .spi = panel.device() }, .{ .spi = .{ .channel = @intCast(index), .select = 0 } }, 0);
            };
        }
        if (board.asks.attached_eink) |panel| out.attached_panel = try g.add(board, .{ .spi = panel.device() }, .{ .spi = .{ .channel = 0, .select = 0 } }, 0);
        if (board.pins.observer) |observer| {
            if (c.esp_hosted.snapshot.observerMatches(&board.c6, &board.pins)) {
                out.observer = try g.add(board, .{ .uart = board.c6.device() }, .{ .uart = .{ .channel = 2 } }, 0);
            }
            for (g.nodes[0..g.count], 0..) |node, id| {
                if (codec.context(node.device) != observer.context) continue;
                if (!(node.kind == .part and node.kind.part == .c6 or node.kind == .builtin and node.kind.builtin == .c6)) continue;
                if (c.esp_hosted.snapshot.observerMatches(codec.cast(c.esp_hosted.C6, observer.context), &board.pins)) out.observer = @intCast(id);
            }
        }
        return out;
    }

    pub fn write(self: *const Topology, writer: *std.Io.Writer) !void {
        try fields.writeExcept(writer, self.*, .{ "asks", "fitted" });
        for (self.asks[0..self.ask_count]) |ask| try fields.write(writer, ask);
        for (self.fitted[0..self.fitted_count]) |fitted| try fields.write(writer, fitted);
    }

    pub fn read(cursor: *fields.Cursor, g: *const graph.Graph) !Topology {
        var out: Topology = .{};
        try fields.readOver(cursor, &out, .{ "asks", "fitted" });
        if (out.ask_count > out.asks.len or out.fitted_count > out.fitted.len) return error.BadValue;
        for (out.asks[0..out.ask_count]) |*ask| {
            ask.* = try fields.read(Ask, cursor);
            if (!nodes.validEndpoint(ask.at)) return error.BadValue;
            if (ask.tag) |tag| {
                if (c.parts.all.find(codec.name(tag)).?.kind != ask.at.kind()) return error.BadValue;
            } else if (ask.at != .i2c or ask.fault == null) return error.BadValue;
            if (ask.tag == .c6 and (ask.at != .uart or ask.at.uart.channel != 2)) return error.BadValue;
            if (ask.fault) |mode| {
                if (ask.at == .gpio) return error.BadValue;
                if (ask.at != .i2c) switch (mode) {
                    .disconnected, .stuck, .garbage => {},
                    else => return error.BadValue,
                };
                if (mode == .nack_every and mode.nack_every == 0) return error.BadValue;
            }
            if (ask.geometry) |shape| {
                if (ask.tag != .panel or shape.width == 0 or shape.height == 0 or shape.width > 4096 or shape.height > 4096) return error.BadValue;
            }
        }
        for (out.fitted[0..out.fitted_count], 0..) |*fitted, index| {
            fitted.* = try fields.read(Fitted, cursor);
            if (!nodes.validEndpoint(fitted.at) or c.parts.all.find(codec.name(fitted.tag)).?.kind != fitted.at.kind()) return error.BadValue;
            for (out.fitted[0..index]) |previous| if (std.meta.eql(previous.at, fitted.at)) return error.BadValue;
        }
        try out.validate(g);
        return out;
    }

    fn fittedNode(self: *const Topology, at: Endpoint) ?u16 {
        switch (at) {
            .i2c => |where| {
                for (self.i2c[@backingInt(where.line)]) |entry| if (entry) |ref| {
                    if (ref.at.i2c.address == where.address) return ref.id;
                };
            },
            .spi => |where| if (self.spi[where.channel]) |ref| {
                if (ref.at.spi.select == where.select) return ref.id;
            },
            .uart => |where| if (self.uart[where.channel]) |ref| {
                return ref.id;
            },
            .gpio => for (self.gpio) |entry| if (entry) |ref| {
                if (std.meta.eql(ref.at, at)) return ref.id;
            },
        }
        return null;
    }

    fn validate(self: *const Topology, g: *const graph.Graph) !void {
        for (self.i2c, 0..) |line, which| for (line, 0..) |entry, index| if (entry) |ref| {
            try validRef(ref, .i2c, g);
            if (@backingInt(ref.at.i2c.line) != which) return error.BadValue;
            for (line[0..index]) |previous| if (previous) |one| if (one.at.i2c.address == ref.at.i2c.address) return error.BadValue;
        };
        for (self.spi, 0..) |entry, index| if (entry) |ref| {
            try validRef(ref, .spi, g);
            if (ref.at.spi.channel != index) return error.BadValue;
        };
        for (self.uart, 0..) |entry, index| if (entry) |ref| {
            try validRef(ref, .uart, g);
            if (ref.at.uart.channel != index) return error.BadValue;
        };
        var hole = false;
        for (self.gpio, 0..) |entry, index| {
            if (entry) |ref| {
                if (hole) return error.BadValue;
                try validRef(ref, .gpio, g);
                for (self.gpio[0..index]) |previous| if (previous) |one| if (std.meta.eql(one.at, ref.at)) return error.BadValue;
            } else hole = true;
        }
        for (self.fitted[0..self.fitted_count]) |fit| {
            const id = self.fittedNode(fit.at) orelse return error.BadValue;
            if (baseTag(id, g) != fit.tag) return error.BadValue;
        }
        for (self.panels) |entry| if (entry) |id| try validPanel(id, g);
        if (self.attached_panel) |id| try validPanel(id, g);
        if (self.observer) |id| {
            if (id >= g.count) return error.BadValue;
            const kind = g.nodes[id].kind;
            if (!(kind == .part and kind.part == .c6 or kind == .builtin and kind.builtin == .c6)) return error.BadValue;
        }
    }
};

fn validRef(ref: Ref, kind: c.endpoint.Kind, g: *const graph.Graph) !void {
    if (ref.id >= g.count or ref.at.kind() != kind or !nodes.validEndpoint(ref.at)) return error.BadValue;
    const node = g.nodes[ref.id];
    if (codec.kindOf(node.device) != kind) return error.BadValue;
    if (kind == .i2c and node.device.i2c.address != ref.at.i2c.address) return error.BadValue;
}

fn validPanel(id: u16, g: *const graph.Graph) !void {
    if (id >= g.count) return error.BadValue;
    const kind = g.nodes[id].kind;
    if (!(kind == .part and kind.part == .panel or kind == .builtin and kind.builtin == .panel)) return error.BadValue;
}

fn baseTag(initial: u16, g: *const graph.Graph) ?codec.Tag {
    var id = initial;
    while (g.nodes[id].inner) |inner| id = inner;
    return switch (g.nodes[id].kind) {
        .part => |tag| tag,
        .builtin => |tag| switch (tag) {
            .imu => .imu,
            .gauge => .gauge,
            .panel => .panel,
            .modem => .modem,
            .c6 => .c6,
            else => null,
        },
        else => null,
    };
}
