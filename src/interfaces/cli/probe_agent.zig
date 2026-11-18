//! Native probe-host listener (`ra8_emulator probe-agent`): mutually
//! authenticates backend peers with an operator-provisioned HMAC-SHA256 secret,
//! publishes local probe targets for its pinned `host_id`, gives each peer a
//! claim token checked on every later request, and drops a peer's reservation
//! immediately on disconnect. Only the handshake is authenticated: later frames
//! carry no MAC, so the link belongs on loopback, SSH or a trusted segment.
const builtin = @import("builtin");
const std = @import("std");

const host = @import("ra8_host");
const listen = @import("serve/listen.zig");
const loop = @import("serve/loop.zig");
const target_bindings = @import("serve/targets.zig");

const auth = host.probe_host.auth;
const model = host.targets;
const sock_ready = host.sock.ready;
const win32 = host.win32;
const wire = host.probe_host.wire;

pub const Args = struct {
    targets: []const u8,
    secret_file: []const u8,
    host_id: []const u8,
    address: std.Io.net.IpAddress,
};

pub const Peer = struct {
    stream: std.Io.net.Stream = undefined,
    owner: u8 = 0,
    token: u64 = 0,
};

const RawFlags = struct {
    targets: ?[]const u8 = null,
    secret: ?[]const u8 = null,
    host_id: ?[]const u8 = null,
    spec: ?listen.Spec = null,
};

pub fn parse(argv: []const []const u8) !Args {
    if (argv.len != 10 or !std.mem.eql(u8, argv[1], "probe-agent")) return error.BadArguments;
    var raw: RawFlags = .{};
    var index: usize = 2;
    while (index < argv.len) : (index += 2) {
        try applyFlag(&raw, argv[index], argv[index + 1]);
    }
    const tcp = switch (raw.spec orelse return error.BadArguments) {
        .tcp => |addr| addr,
        .unix => return error.BadArguments,
    };
    const id = raw.host_id orelse return error.BadArguments;
    if (id.len == 0) return error.BadArguments;
    return .{
        .targets = raw.targets orelse return error.BadArguments,
        .secret_file = raw.secret orelse return error.BadArguments,
        .host_id = id,
        .address = tcp,
    };
}

fn applyFlag(raw: *RawFlags, flag: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, flag, "--targets") and raw.targets == null) {
        raw.targets = value;
    } else if (std.mem.eql(u8, flag, "--secret-file") and raw.secret == null) {
        raw.secret = value;
    } else if (std.mem.eql(u8, flag, "--host-id") and raw.host_id == null) {
        raw.host_id = value;
    } else if (std.mem.eql(u8, flag, "--listen") and raw.spec == null) {
        raw.spec = try listen.Spec.parse(value);
    } else return error.BadArguments;
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !u8 {
    const args = parse(argv) catch |err| {
        std.debug.print("probe-agent: {s}\n", .{@errorName(err)});
        return 2;
    };
    const key = auth.readKey(io, args.secret_file) catch |err| {
        std.debug.print("probe-agent: secret: {s}\n", .{@errorName(err)});
        return 1;
    };
    var inventory: target_bindings.Inventory = .{};
    defer inventory.close();
    inventory.open(allocator, io, args.targets, null) catch |err| {
        std.debug.print("probe-agent: targets: {s}\n", .{@errorName(err)});
        return 1;
    };
    serve(allocator, io, args, key, &inventory.registry) catch |err| {
        std.debug.print("probe-agent: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

pub const State = struct {
    io: std.Io,
    host_id: []const u8,
    registry: *model.Registry,
    next_token: u64 = 0,
    peers: [8]?Peer = @splat(null),

    fn closeAll(self: *State) void {
        for (&self.peers) |*slot| if (slot.*) |*peer| {
            self.registry.release(&peer.owner);
            peer.stream.close(self.io);
            slot.* = null;
        };
    }
};

fn serve(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: Args,
    key: auth.Key,
    registry: *model.Registry,
) !void {
    var addr = args.address;
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    catchStops();
    std.debug.print("probe-agent: listening on tcp:{f}\n", .{server.socket.address});
    var state: State = .{ .io = io, .host_id = args.host_id, .registry = registry };
    defer state.closeAll();
    while (!loop.stopping.load(.acquire)) {
        if ((try sock_ready.wait(io, server.socket.handle, 10)).any()) {
            acceptOne(io, &server, args.host_id, key, &state);
        }
        stepPeers(allocator, &state);
    }
}

fn acceptOne(io: std.Io, server: *std.Io.net.Server, host_id: []const u8, key: auth.Key, state: *State) void {
    var client = server.accept(io) catch return;
    for (&state.peers) |*slot| if (slot.* == null) {
        var tx: [1024]u8 = undefined;
        var rx: [1024]u8 = undefined;
        var writer = client.writer(io, &tx);
        var reader = client.reader(io, &rx);
        auth.authenticateAgent(io, &reader.interface, &writer.interface, host_id, key) catch {
            client.close(io);
            return;
        };
        slot.* = .{ .stream = client };
        return;
    };
    client.close(io);
}

fn stepPeers(allocator: std.mem.Allocator, state: *State) void {
    for (&state.peers) |*slot| if (slot.*) |*peer| {
        const ready = sock_ready.wait(state.io, peer.stream.socket.handle, 1) catch {
            dropPeer(state, slot);
            continue;
        };
        if (!ready.any()) continue;
        handleOne(allocator, state, peer) catch dropPeer(state, slot);
    };
}

fn dropPeer(state: *State, slot: *?Peer) void {
    if (slot.*) |*peer| {
        state.registry.release(&peer.owner);
        peer.stream.close(state.io);
        slot.* = null;
    }
}

fn handleOne(allocator: std.mem.Allocator, state: *State, peer: *Peer) !void {
    var tx: [4096]u8 = undefined;
    var scratch: [wire.max_line]u8 = undefined;
    var writer = peer.stream.writer(state.io, &tx);
    const parsed = try wire.receiveSocket(
        wire.Request,
        allocator,
        state.io,
        peer.stream.socket.handle,
        &scratch,
        5_000,
    );
    defer parsed.deinit();
    var out: [16384]u8 = undefined;
    var snaps: [32]wire.Snapshot = undefined;
    const reply = dispatch(state, peer, parsed.value, &snaps, &out) catch |err| wire.Reply{
        .ok = false,
        .err = @errorName(err),
    };
    try wire.send(&writer.interface, reply);
}

pub fn dispatch(
    state: *State,
    peer: *Peer,
    req: wire.Request,
    snaps: *[32]wire.Snapshot,
    out: []u8,
) !wire.Reply {
    return switch (req.op) {
        .list => .{ .ok = true, .targets = listTargets(state, snaps) },
        .claim => claimTarget(state, peer, req),
        .release => releaseTarget(state, peer, req),
        .perform => performTarget(state, peer, req, out),
    };
}

fn listTargets(state: *State, snaps: *[32]wire.Snapshot) []const wire.Snapshot {
    state.registry.refresh();
    var count: usize = 0;
    for (state.registry.entries) |slot| if (slot) |entry| {
        if (!std.mem.eql(u8, entry.target.host_id, state.host_id)) continue;
        snaps[count] = snapshot(entry.target);
        count += 1;
    };
    return snaps[0..count];
}

fn claimTarget(state: *State, peer: *Peer, req: wire.Request) !wire.Reply {
    state.registry.refresh();
    const sel = try selectionFor(state.registry, state.host_id, req.probe_id, req.board_id);
    try state.registry.reserve(&peer.owner, sel);
    // A per-connection claim token, not a fence: the persisted J-Link lease
    // counter in the provider is what fences the probe across processes.
    state.next_token += 1;
    peer.token = state.next_token;
    return .{ .ok = true, .token = peer.token };
}

fn releaseTarget(state: *State, peer: *Peer, req: wire.Request) !wire.Reply {
    if (req.token == 0 or peer.token != req.token) return error.StaleLease;
    state.registry.release(&peer.owner);
    peer.token = 0;
    return .{ .ok = true };
}

fn performTarget(state: *State, peer: *Peer, req: wire.Request, out: []u8) !wire.Reply {
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

fn catchStops() void {
    if (builtin.os.tag == .windows) {
        _ = win32.SetConsoleCtrlHandler(onConsoleStop, .TRUE);
        return;
    }
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = onStop },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &action, null);
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
    std.posix.sigaction(std.posix.SIG.HUP, &action, null);
    std.posix.sigaction(std.posix.SIG.QUIT, &action, null);
}

fn onStop(_: std.posix.SIG) callconv(.c) void {
    loop.stopping.store(true, .release);
}

fn onConsoleStop(_: win32.DWORD) callconv(.winapi) win32.BOOL {
    loop.stopping.store(true, .release);
    return .TRUE;
}
