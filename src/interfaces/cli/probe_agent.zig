//! Native probe-host agent (`ra8_emulator probe-agent`): supports TCP listener
//! mode (`--listen tcp:HOST:PORT`), host-profile spawned pipe mode (`--stdio`),
//! and OS/probe/transport matrix inspection (`--matrix`). Every frame after the
//! `RA8PH2` handshake carries a directional HMAC-SHA256 and monotonic sequence
//! number, flash/debug operations stream progress chunks before the finite
//! reply, and peer disconnect drops reservations and staged images immediately.
const builtin = @import("builtin");
const std = @import("std");

const host = @import("ra8_host");
const listen = @import("serve/listen.zig");
const loop = @import("serve/loop.zig");
const probe_dispatch = @import("probe_dispatch.zig");
const probe_stage = @import("probe_stage.zig");
const target_bindings = @import("serve/targets.zig");

const auth = host.probe_host.auth;
const matrix = host.probe_host.matrix;
const model = host.targets;
const sock_ready = host.sock.ready;
const win32 = host.win32;
const wire = host.probe_host.wire;

pub const Mode = union(enum) {
    matrix,
    serve: struct {
        targets: []const u8,
        secret_file: []const u8,
        host_id: []const u8,
        where: union(enum) { stdio, tcp: std.Io.net.IpAddress },
    },
};

pub const Peer = struct {
    stream: std.Io.net.Stream = undefined,
    session: auth.Session = .{ .tx_key = @splat(0), .rx_key = @splat(0) },
    owner: u8 = 0,
    token: u64 = 0,
    stage: probe_stage.Stage = .{},
};

const RawFlags = struct {
    targets: ?[]const u8 = null,
    secret: ?[]const u8 = null,
    host_id: ?[]const u8 = null,
    spec: ?listen.Spec = null,
    stdio: bool = false,
};

pub fn parse(argv: []const []const u8) !Mode {
    if (argv.len < 3 or !std.mem.eql(u8, argv[1], "probe-agent")) return error.BadArguments;
    if (argv.len == 3 and std.mem.eql(u8, argv[2], "--matrix")) return .matrix;
    var raw: RawFlags = .{};
    var index: usize = 2;
    while (index < argv.len) {
        if (std.mem.eql(u8, argv[index], "--stdio") and !raw.stdio) {
            raw.stdio = true;
            index += 1;
            continue;
        }
        if (index + 1 >= argv.len) return error.BadArguments;
        try applyFlag(&raw, argv[index], argv[index + 1]);
        index += 2;
    }
    if (raw.stdio == (raw.spec != null)) return error.BadArguments;
    const id = raw.host_id orelse return error.BadArguments;
    if (id.len == 0) return error.BadArguments;
    return .{ .serve = .{
        .targets = raw.targets orelse return error.BadArguments,
        .secret_file = raw.secret orelse return error.BadArguments,
        .host_id = id,
        .where = if (raw.stdio) .stdio else .{ .tcp = switch (raw.spec.?) {
            .tcp => |addr| addr,
            .unix => return error.BadArguments,
        } },
    } };
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
    const mode = parse(argv) catch |err| {
        std.debug.print("probe-agent: {s}\n", .{@errorName(err)});
        return 2;
    };
    switch (mode) {
        .matrix => {
            var buf: [4096]u8 = undefined;
            var stdout = std.Io.File.stdout().writerStreaming(io, &buf);
            try matrix.writeJson(&stdout.interface);
            try stdout.interface.writeByte('\n');
            try stdout.interface.flush();
            return 0;
        },
        .serve => |args| return runAgent(allocator, io, args),
    }
}

fn runAgent(allocator: std.mem.Allocator, io: std.Io, args: anytype) !u8 {
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
    const outcome = switch (args.where) {
        .stdio => serveStdio(allocator, io, args.host_id, key, &inventory.registry),
        .tcp => |addr| serveTcp(allocator, io, args.host_id, addr, key, &inventory.registry),
    };
    outcome catch |err| {
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
            peer.stage.drop();
            self.registry.release(&peer.owner);
            peer.stream.close(self.io);
            slot.* = null;
        };
    }
};

fn serveStdio(
    allocator: std.mem.Allocator,
    io: std.Io,
    host_id: []const u8,
    key: auth.Key,
    registry: *model.Registry,
) !void {
    const stdin = std.Io.File.stdin();
    var tx: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &tx);
    var peer: Peer = .{
        .session = try auth.authenticateAgentFrom(io, .{ .pipe = .{ .file = stdin } }, &writer.interface, host_id, key),
    };
    var state: State = .{ .io = io, .host_id = host_id, .registry = registry };
    defer {
        peer.stage.drop();
        state.registry.release(&peer.owner);
    }
    while (true) {
        var scratch: [wire.max_line]u8 = undefined;
        const parsed = wire.receivePipe(
            wire.Request,
            allocator,
            io,
            stdin,
            &peer.session,
            &scratch,
            300_000,
        ) catch |err| {
            if (err == error.AgentDisconnected) return;
            return err;
        };
        defer parsed.deinit();
        try answerPeer(&state, &peer, parsed.value, &writer.interface);
    }
}

fn serveTcp(
    allocator: std.mem.Allocator,
    io: std.Io,
    host_id: []const u8,
    address: std.Io.net.IpAddress,
    key: auth.Key,
    registry: *model.Registry,
) !void {
    var addr = address;
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    catchStops();
    std.debug.print("probe-agent: listening on tcp:{f}\n", .{server.socket.address});
    var state: State = .{ .io = io, .host_id = host_id, .registry = registry };
    defer state.closeAll();
    while (!loop.stopping.load(.acquire)) {
        if ((try sock_ready.wait(io, server.socket.handle, 10)).any()) {
            acceptOne(io, &server, host_id, key, &state);
        }
        stepPeers(allocator, &state);
    }
}

fn acceptOne(io: std.Io, server: *std.Io.net.Server, host_id: []const u8, key: auth.Key, state: *State) void {
    var client = server.accept(io) catch return;
    for (&state.peers) |*slot| if (slot.* == null) {
        var tx: [1024]u8 = undefined;
        var writer = client.writer(io, &tx);
        const session = auth.authenticateAgentFrom(
            io,
            .{ .socket = .{ .handle = client.socket.handle } },
            &writer.interface,
            host_id,
            key,
        ) catch {
            client.close(io);
            return;
        };
        slot.* = .{ .stream = client, .session = session };
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
        peer.stage.drop();
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
        &peer.session,
        &scratch,
        10_000,
    );
    defer parsed.deinit();
    try answerPeer(state, peer, parsed.value, &writer.interface);
}

fn answerPeer(state: *State, peer: *Peer, req: wire.Request, writer: *std.Io.Writer) !void {
    if (req.op == .perform) {
        try wire.send(writer, &peer.session, wire.Reply{ .ok = true, .chunk = true, .stream = @tagName(req.action) });
    } else if (req.op == .flash_commit) {
        try wire.send(writer, &peer.session, wire.Reply{ .ok = true, .chunk = true, .stream = "flash:program_verify" });
    }
    var out: [16384]u8 = undefined;
    var snaps: [32]wire.Snapshot = undefined;
    const reply = dispatch(state, peer, req, &snaps, &out) catch |err| wire.Reply{
        .ok = false,
        .err = @errorName(err),
    };
    try wire.send(writer, &peer.session, reply);
}

pub fn dispatch(
    state: *State,
    peer: *Peer,
    req: wire.Request,
    snaps: *[32]wire.Snapshot,
    out: []u8,
) !wire.Reply {
    return probe_dispatch.execute(state, peer, req, snaps, out);
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
