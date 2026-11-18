//! Request dispatch for `probe-agent` peers: inventory snapshots, claim/release
//! lease tokens, bounded action execution, and chunked ELF flash commit.
const std = @import("std");

const host = @import("ra8_host");

const model = host.targets;
const wire = host.probe_host.wire;

pub fn execute(
    state: anytype,
    peer: anytype,
    req: wire.Request,
    snaps: *[32]wire.Snapshot,
    out: []u8,
) !wire.Reply {
    return switch (req.op) {
        .list => .{ .ok = true, .targets = listTargets(state, snaps) },
        .claim => claimTarget(state, peer, req),
        .release => releaseTarget(state, peer, req),
        .perform => performTarget(state, peer, req, out),
        .flash_begin => beginFlash(peer, req),
        .flash_chunk => chunkFlash(peer, req),
        .flash_commit => commitFlash(state, peer, req, out),
    };
}

fn beginFlash(peer: anytype, req: wire.Request) !wire.Reply {
    if (req.token == 0 or peer.token != req.token) return error.StaleLease;
    try peer.stage.begin(std.heap.page_allocator, req.total_len, req.sha256);
    return .{ .ok = true };
}

fn chunkFlash(peer: anytype, req: wire.Request) !wire.Reply {
    if (req.token == 0 or peer.token != req.token) return error.StaleLease;
    try peer.stage.chunk(req.offset, req.hex);
    return .{ .ok = true };
}

fn commitFlash(state: anytype, peer: anytype, req: wire.Request, out: []u8) !wire.Reply {
    if (req.token == 0 or peer.token != req.token) return error.StaleLease;
    const elf = try peer.stage.finish();
    defer std.heap.page_allocator.free(elf);
    const sel = try selectionFor(state.registry, state.host_id, req.probe_id, req.board_id);
    const json = try state.registry.flash(&peer.owner, sel, elf, out);
    return .{ .ok = true, .json = json };
}

fn listTargets(state: anytype, snaps: *[32]wire.Snapshot) []const wire.Snapshot {
    state.registry.refresh();
    var count: usize = 0;
    for (state.registry.entries) |slot| if (slot) |entry| {
        if (!std.mem.eql(u8, entry.target.host_id, state.host_id)) continue;
        snaps[count] = snapshot(entry.target);
        count += 1;
    };
    return snaps[0..count];
}

fn claimTarget(state: anytype, peer: anytype, req: wire.Request) !wire.Reply {
    state.registry.refresh();
    const sel = try selectionFor(state.registry, state.host_id, req.probe_id, req.board_id);
    try state.registry.reserve(&peer.owner, sel);
    state.next_token += 1;
    peer.token = state.next_token;
    return .{ .ok = true, .token = peer.token };
}

fn releaseTarget(state: anytype, peer: anytype, req: wire.Request) !wire.Reply {
    if (req.token == 0 or peer.token != req.token) return error.StaleLease;
    peer.stage.drop();
    state.registry.release(&peer.owner);
    peer.token = 0;
    return .{ .ok = true };
}

fn performTarget(state: anytype, peer: anytype, req: wire.Request, out: []u8) !wire.Reply {
    if (req.token == 0 or peer.token != req.token) return error.StaleLease;
    const sel = try selectionFor(state.registry, state.host_id, req.probe_id, req.board_id);
    const json = try state.registry.perform(&peer.owner, sel, req.action, out);
    return .{ .ok = true, .json = json };
}

fn selectionFor(
    registry: *model.Registry,
    host_id: []const u8,
    probe_id: []const u8,
    board_id: []const u8,
) !model.Selection {
    for (registry.entries) |slot| if (slot) |entry| {
        const t = entry.target;
        if (!std.mem.eql(u8, t.host_id, host_id)) continue;
        if (!std.mem.eql(u8, t.probe_id, probe_id) or !std.mem.eql(u8, t.board_id, board_id)) continue;
        return .{
            .host_id = t.host_id,
            .probe_id = t.probe_id,
            .board_id = t.board_id,
            .generation = entry.generation,
            .disambiguation = t.disambiguation,
        };
    };
    return error.StaleSelection;
}

fn snapshot(t: model.Descriptor) wire.Snapshot {
    return .{
        .probe_id = t.probe_id,
        .board_id = t.board_id,
        .probe_serial = t.probe_serial,
        .board_serial = t.board_serial,
        .vendor = t.vendor,
        .model = t.model,
        .cores = t.cores,
        .transport = t.transport,
        .connected = t.connection != .disconnected,
        .uart = t.uart,
        .disambiguation = t.disambiguation,
        .identity_verified = t.identity_verified,
        .managed = t.managed,
        .operations = t.operations,
        .capabilities = t.capabilities,
    };
}
