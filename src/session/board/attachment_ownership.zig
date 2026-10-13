//! Object identity is ownership evidence; slots and callback shapes are not.
const c = @import("ra8_components");
const Board = @import("ra8_board").board.Board;
const Plugs = @import("plug.zig").Plugs;
const nodes = @import("attachment_nodes.zig");
const codec = c.catalog_snapshot;
const Endpoint = c.endpoint.Endpoint;

/// Follow a fault to a persistently owned object, without invoking callbacks.
pub fn endpoint(board: *Board, plugs: ?*const Plugs, device: c.catalog.Device, fallback: Endpoint) !Endpoint {
    var current = device;
    for (0..65) |_| {
        for (board.asks.owned[0..board.asks.owned_count]) |owned| {
            if (same(owned.instance.device, current)) return owned.at;
        }
        if (plugs) |held| {
            for (held.instances[0..held.instance_count], 0..) |instance, index| {
                if (same(instance.device, current)) return held.instance_endpoints[index];
            }
            for (held.snapshot_owned[0..held.snapshot_owned_count], 0..) |instance, index| {
                if (same(instance.device, current)) return held.snapshot_endpoints[index];
            }
        }
        const kind = try nodes.classify(board, current, fallback);
        current = nodes.innerOf(.{ .kind = kind, .at = fallback, .device = current }) orelse return fallback;
    }
    return error.UnsupportedAttachment;
}

fn same(a: c.catalog.Device, b: c.catalog.Device) bool {
    return codec.context(a) == codec.context(b) and codec.sameCallbacks(a, b);
}

/// Only actual startup allocations are destroyed; borrowed roots stay borrowed.
pub fn destroyStartup(board: *Board, plugs: *const Plugs) void {
    const allocator = board.asks.arena orelse return;
    for (board.asks.owned[0..board.asks.owned_count]) |owned| {
        var tracked = false;
        for (plugs.instances[0..plugs.instance_count]) |instance| {
            if (instance.state == owned.instance.state) tracked = true;
        }
        for (plugs.snapshot_owned[0..plugs.snapshot_owned_count]) |instance| {
            if (instance.state == owned.instance.state) tracked = true;
        }
        if (!tracked) c.catalog.Catalog.destroy(allocator, owned.instance);
    }
    board.asks.owned_count = 0;
}
