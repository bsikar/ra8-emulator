//! Install the validated graph and transfer host ownership only at commit.
const std = @import("std");
const c = @import("ra8_components");
const Board = @import("ra8_board").board.Board;
const codec = c.catalog_snapshot;
const graph = @import("attachment_graph.zig");
const Topology = @import("attachment_topology.zig").Topology;
const Binding = @import("attachments.zig").Binding;
const Plugs = @import("plug.zig").Plugs;
const Faults = @import("faults/faults.zig").Faults;
const ownership = @import("attachment_ownership.zig");
const nodes = @import("attachment_nodes.zig");

pub fn commit(next: *graph.Graph, previous: *graph.Graph, top: *const Topology, arena: *std.heap.ArenaAllocator, board: *Board, binding: ?Binding) void {
    const donors = matchProviders(next, previous);
    for (next.nodes[0..next.count], 0..) |node, id| {
        if (node.kind != .part) continue;
        const old: ?nodes.Node = if (donors[id]) |old_id| previous.nodes[old_id] else null;
        retainWiring(node, old, board);
    }
    if (board.pins.observer) |observer| {
        for (previous.nodes[0..previous.count]) |node| {
            if (node.kind != .part or node.kind.part != .c6 or codec.context(node.device) != observer.context) continue;
            if (c.esp_hosted.snapshot.observerMatches(codec.cast(c.esp_hosted.C6, observer.context), &board.pins)) board.pins.observer = null;
        }
    }
    if (binding) |held| {
        ownership.destroyStartup(board, held.plugs);
        held.plugs.deinit();
        held.arena.deinit();
        held.arena.* = arena.*;
        arena.* = .init(held.arena.child_allocator);
        held.plugs.* = Plugs.init(board, held.arena.allocator());
        held.plugs.fitted_count = 0;
        held.faults.* = Faults.init(board, held.arena.allocator());
        installOwners(next, top, held);
        board.asks.arena = held.arena.allocator();
    } else arena.deinit();
    installTopology(next, top, board);
}

/// Runtime ordinals are persistent bindings. Reserve them before fallback can
/// consume one; startup/restored extras prefer other nonruntime donors.
fn matchProviders(next: *const graph.Graph, previous: *const graph.Graph) [nodes.limit]?u16 {
    var donors: [nodes.limit]?u16 = @splat(null);
    var moved: [nodes.limit]bool = @splat(false);
    const next_runtime = runtimeParts(next);
    const old_runtime = runtimeParts(previous);
    for (next.runtime[0..next.runtime_count], 0..) |entry, index| {
        if (index >= previous.runtime_count) continue;
        const id = entry.?;
        const old_id = previous.runtime[index].?;
        if (!moved[old_id] and compatible(next.nodes[id], previous.nodes[old_id])) {
            moved[old_id] = true;
            donors[id] = old_id;
        }
    }
    for (next.nodes[0..next.count], 0..) |wanted, id| {
        if (wanted.kind != .part or donors[id] != null) continue;
        donors[id] = matching(wanted, previous, &moved, &old_runtime, next_runtime[id]);
        if (donors[id] == null) donors[id] = matching(wanted, previous, &moved, &old_runtime, null);
    }
    return donors;
}

fn runtimeParts(g: *const graph.Graph) [nodes.limit]bool {
    var result: [nodes.limit]bool = @splat(false);
    for (g.runtime[0..g.runtime_count]) |entry| result[entry.?] = true;
    return result;
}

fn compatible(wanted: nodes.Node, old: nodes.Node) bool {
    return wanted.kind == .part and old.kind == .part and old.kind.part == wanted.kind.part and std.meta.eql(old.at, wanted.at);
}

fn matching(wanted: nodes.Node, previous: *const graph.Graph, moved: *[nodes.limit]bool, runtime: *const [nodes.limit]bool, role: ?bool) ?u16 {
    for (previous.nodes[0..previous.count], 0..) |old, old_id| {
        if (moved[old_id] or !compatible(wanted, old)) continue;
        if (role) |wanted_role| if (runtime[old_id] != wanted_role) continue;
        moved[old_id] = true;
        return @intCast(old_id);
    }
    return null;
}

fn retainWiring(node: @import("attachment_nodes.zig").Node, old: ?@import("attachment_nodes.zig").Node, board: *Board) void {
    const state = codec.context(node.device);
    if (node.kind.part == .panel) {
        const panel = codec.cast(c.eink.Panel, state);
        const target = if (old) |held| codec.cast(c.eink.Panel, codec.context(held.device)) else &board.panel;
        panel.refresh_hook = target.refresh_hook;
        panel.refresh_log_hook = target.refresh_log_hook;
        panel.event_hook = target.event_hook;
    }
    if (node.kind.part == .c6) {
        const part = codec.cast(c.esp_hosted.C6, state);
        if (old) |held| {
            const target = codec.cast(c.esp_hosted.C6, codec.context(held.device));
            target.wire.bridge.closeFlows();
            part.wire.bridge = target.wire.bridge;
            target.wire.bridge = .{};
        }
        part.pins = &board.pins;
    }
}

fn installOwners(next: *graph.Graph, top: *const Topology, held: Binding) void {
    var runtime: [512]bool = @splat(false);
    for (next.runtime[0..next.runtime_count]) |entry| {
        const id = entry.?;
        runtime[id] = true;
        held.plugs.instances[held.plugs.instance_count] = instanceOf(next.nodes[id]);
        held.plugs.instance_endpoints[held.plugs.instance_count] = next.nodes[id].at;
        held.plugs.instance_count += 1;
    }
    for (next.nodes[0..next.count], 0..) |node, id| {
        if (node.kind != .part) continue;
        if (node.kind.part == .panel) codec.cast(c.eink.Panel, codec.context(node.device)).planes.allocator = held.arena.allocator();
        if (runtime[id]) continue;
        held.plugs.snapshot_owned[held.plugs.snapshot_owned_count] = instanceOf(node);
        held.plugs.snapshot_endpoints[held.plugs.snapshot_owned_count] = node.at;
        held.plugs.snapshot_owned_count += 1;
    }
    for (top.fitted[0..top.fitted_count]) |fit| {
        held.plugs.fitted[held.plugs.fitted_count] = .{ .name = codec.name(fit.tag), .at = fit.at };
        held.plugs.fitted_count += 1;
    }
    for (top.panels, 0..) |entry, index| held.plugs.panels[index] = if (entry) |id| codec.cast(c.eink.Panel, codec.context(next.nodes[id].device)) else null;
    for (next.wrapped, 0..) |entry, index| held.faults.wrapped[index] = if (entry) |id| codec.cast(c.fault.I2c, codec.context(next.nodes[id].device)) else null;
    for (next.spi_held, 0..) |entry, index| held.faults.spi_parts.held[index] = if (entry) |id| codec.cast(c.fault.lines.Spi, codec.context(next.nodes[id].device)) else null;
    for (next.uart_held, 0..) |entry, index| held.faults.uart_parts.held[index] = if (entry) |id| codec.cast(c.fault.lines.Uart, codec.context(next.nodes[id].device)) else null;
}

fn instanceOf(node: @import("attachment_nodes.zig").Node) c.catalog.Instance {
    return .{ .model = c.parts.all.find(codec.name(node.kind.part)).?, .state = codec.context(node.device), .device = node.device };
}

fn installTopology(next: *graph.Graph, top: *const Topology, board: *Board) void {
    const registries = [_]*@TypeOf(board.wire.controller.devices){ &board.wire.controller.devices, &board.wire.touchline.devices };
    for (registries, 0..) |registry, line| for (&registry.devices, top.i2c[line]) |*slot, entry| {
        slot.* = if (entry) |ref| next.nodes[ref.id].device.i2c else null;
    };
    for (&board.spi.channels, top.spi) |*unit, entry| unit.device = if (entry) |ref| next.nodes[ref.id].device.spi else null;
    for (&board.serial.channels, top.uart) |*unit, entry| unit.device = if (entry) |ref| next.nodes[ref.id].device.uart else null;
    board.pins.wired.count = 0;
    for (top.gpio) |entry| if (entry) |ref| {
        const index = board.pins.wired.count;
        board.pins.wired.slots[index] = .{ .port = ref.at.gpio.port, .pin = ref.at.gpio.pin, .device = next.nodes[ref.id].device.gpio };
        board.pins.wired.count += 1;
    };
    board.asks.count = top.ask_count;
    for (top.asks[0..top.ask_count], 0..) |ask, index| board.asks.asked[index] = .{ .name = if (ask.tag) |tag| codec.name(tag) else "", .at = ask.at, .fault = ask.fault, .geometry = ask.geometry };
    board.asks.attached_eink = if (top.attached_panel) |id| codec.cast(c.eink.Panel, codec.context(next.nodes[id].device)) else null;
    for (next.nodes[0..next.count], 0..) |node, id| {
        if (!(node.kind == .part and node.kind.part == .c6 or node.kind == .builtin and node.kind.builtin == .c6)) continue;
        c.esp_hosted.snapshot.rebindPins(codec.cast(c.esp_hosted.C6, codec.context(node.device)), &board.pins, top.observer == @as(u16, @intCast(id)));
    }
}
