const std = @import("std");

const cli = @import("cli_app");
const ra8 = @import("ra8");

const agent = cli.serve.agent;
const auth = ra8.host.probe_host.auth;
const model = ra8.host.targets;
const probe_agent = cli.probe_agent;
const wire = ra8.host.probe_host.wire;

const LogProvider = struct {
    calls: usize = 0,
    flashes: usize = 0,
    fn perform(ctx: *anyopaque, _: model.Action, _: []u8) ![]const u8 {
        const self: *LogProvider = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        return "{\"pc\":1234}";
    }
    fn flash(ctx: *anyopaque, elf: []const u8, out: []u8) ![]const u8 {
        const self: *LogProvider = @ptrCast(@alignCast(ctx));
        self.flashes += 1;
        return std.fmt.bufPrint(out, "{{\"flashed\":true,\"verified\":true,\"bytes\":{d}}}", .{elf.len});
    }
};

fn serveSession(
    io: std.Io,
    server: *std.Io.net.Server,
    host_id: []const u8,
    key: auth.Key,
    state: *probe_agent.State,
    max_requests: usize,
) anyerror!void {
    var stream = try server.accept(io);
    // Stop listening once connected so dropping the session also refuses reconnects.
    server.deinit(io);
    defer stream.close(io);
    var rx: [2048]u8 = undefined;
    var tx: [2048]u8 = undefined;
    var reader = stream.reader(io, &rx);
    var writer = stream.writer(io, &tx);
    var peer: probe_agent.Peer = .{
        .stream = stream,
        .session = try auth.authenticateAgent(io, &reader.interface, &writer.interface, host_id, key),
    };
    defer state.registry.release(&peer.owner);
    var count: usize = 0;
    while (count < max_requests) : (count += 1) {
        var scratch: [wire.max_line]u8 = undefined;
        const parsed = wire.receive(
            wire.Request,
            std.heap.page_allocator,
            &reader.interface,
            &peer.session,
            &scratch,
        ) catch return;
        defer parsed.deinit();
        if (parsed.value.op == .perform) {
            try wire.send(&writer.interface, &peer.session, wire.Reply{
                .ok = true,
                .chunk = true,
                .stream = @tagName(parsed.value.action),
            });
        } else if (parsed.value.op == .flash_commit) {
            try wire.send(&writer.interface, &peer.session, wire.Reply{
                .ok = true,
                .chunk = true,
                .stream = "flash:program_verify",
            });
        }
        var out: [4096]u8 = undefined;
        var snaps: [32]wire.Snapshot = undefined;
        const reply = probe_agent.dispatch(state, &peer, parsed.value, &snaps, &out) catch |err| wire.Reply{
            .ok = false,
            .err = @errorName(err),
        };
        try wire.send(&writer.interface, &peer.session, reply);
    }
}

test "authenticated probe-host adapter syncs claims streams chunks and disconnects on agent loss" {
    const io = std.testing.io;
    const key: auth.Key = @splat(0x42);
    var remote_reg: model.Registry = .{};
    var log: LogProvider = .{};
    _ = try remote_reg.add(.{
        .host_id = "agent-host",
        .probe_id = "jlink-a",
        .board_id = "fpb-ra8e1",
        .probe_serial = "001083322193",
        .transport = "jlink-usb",
        .connection = .connected,
        .uart = "COM13",
        .identity_verified = true,
        .managed = false,
        .operations = &.{ .registers, .halt, .flash },
        .capabilities = .{ .hardware_debug = true, .flash = true },
    }, .{ .context = &log, .performFn = LogProvider.perform, .flashFn = LogProvider.flash });
    var agent_state: probe_agent.State = .{ .io = io, .host_id = "agent-host", .registry = &remote_reg };

    var bind = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try bind.listen(io, .{ .reuse_address = true });
    const port = server.socket.address.ip4.port;

    var hosts = [1]agent.Host{.{
        .io = io,
        .host_id = "agent-host",
        .spec = .{ .tcp = .{ .address = "127.0.0.1", .port = port } },
        .secret_file = "/secret",
        .key = key,
    }};
    defer hosts[0].close();
    var targets = [1]agent.Target{.{ .descriptor = .{
        .host_id = "agent-host",
        .probe_id = "jlink-a",
        .board_id = "fpb-ra8e1",
        .probe_serial = "001083322193",
        .transport = "jlink-usb",
        .managed = false,
    }, .peer = &hosts[0] }};
    var local_reg: model.Registry = .{};

    const Run = union(enum) { server: anyerror!void, client: anyerror!void };
    var res: [2]Run = undefined;
    var sel: std.Io.Select(Run) = .init(io, &res);
    defer _ = sel.cancel();
    // Serve 6 requests (list, claim, perform, flash_begin, flash_chunk, flash_commit), then close.
    try sel.concurrent(.server, serveSession, .{ io, &server, "agent-host", key, &agent_state, 6 });
    try sel.concurrent(.client, clientFlow, .{ &hosts, &targets, &local_reg });
    try (switch (try sel.await()) {
        .server => |r| r,
        .client => |r| r,
    });
    try (switch (try sel.await()) {
        .server => |r| r,
        .client => |r| r,
    });
    try std.testing.expectEqual(@as(usize, 1), log.calls);
    try std.testing.expectEqual(@as(usize, 1), log.flashes);
    try std.testing.expectEqual(@as(usize, 2), hosts[0].chunks_seen);
}

fn clientFlow(hosts: *[1]agent.Host, targets: *[1]agent.Target, registry: *model.Registry) anyerror!void {
    agent.scanHosts(hosts, targets, registry);
    const first_gen = registry.entries[0].?.generation;
    try std.testing.expectEqualStrings("COM13", registry.entries[0].?.target.uart);
    var owner: u8 = 0;
    const chosen: model.Selection = .{
        .host_id = "agent-host",
        .probe_id = "jlink-a",
        .board_id = "fpb-ra8e1",
        .generation = first_gen,
    };
    try registry.reserve(&owner, chosen);
    var out: [256]u8 = undefined;
    const reply = try registry.perform(&owner, chosen, .registers, &out);
    try std.testing.expectEqualStrings("{\"pc\":1234}", reply);
    const flashed = try registry.flash(&owner, chosen, "remote-elf-bytes", &out);
    try std.testing.expectEqualStrings("{\"flashed\":true,\"verified\":true,\"bytes\":16}", flashed);
    // Next perform hits EOF because the agent dropped after 6 requests.
    try std.testing.expectError(error.AgentDisconnected, registry.perform(&owner, chosen, .halt, &out));
    // Next scan disconnects agent-host and removes the stale entry.
    agent.scanHosts(hosts, targets, registry);
    try std.testing.expect(registry.entries[0] == null);
}

test "authenticated probe-host adapter stages multi-chunk ELF payloads without integer narrowing overflow" {
    const io = std.testing.io;
    const key: auth.Key = @splat(0x24);
    var remote_reg: model.Registry = .{};
    var log: LogProvider = .{};
    _ = try remote_reg.add(.{
        .host_id = "agent-host",
        .probe_id = "jlink-a",
        .board_id = "fpb-ra8e1",
        .probe_serial = "001083322193",
        .transport = "jlink-usb",
        .connection = .connected,
        .identity_verified = true,
        .managed = false,
        .operations = &.{ .registers, .flash },
        .capabilities = .{ .hardware_debug = true, .flash = true },
    }, .{ .context = &log, .performFn = LogProvider.perform, .flashFn = LogProvider.flash });
    var agent_state: probe_agent.State = .{ .io = io, .host_id = "agent-host", .registry = &remote_reg };

    var bind = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try bind.listen(io, .{ .reuse_address = true });
    const port = server.socket.address.ip4.port;

    var hosts = [1]agent.Host{.{
        .io = io,
        .host_id = "agent-host",
        .spec = .{ .tcp = .{ .address = "127.0.0.1", .port = port } },
        .secret_file = "/secret",
        .key = key,
    }};
    defer hosts[0].close();
    var targets = [1]agent.Target{.{ .descriptor = .{
        .host_id = "agent-host",
        .probe_id = "jlink-a",
        .board_id = "fpb-ra8e1",
        .probe_serial = "001083322193",
        .transport = "jlink-usb",
        .managed = false,
    }, .peer = &hosts[0] }};
    var local_reg: model.Registry = .{};

    const Run = union(enum) { server: anyerror!void, client: anyerror!void };
    var res: [2]Run = undefined;
    var sel: std.Io.Select(Run) = .init(io, &res);
    defer _ = sel.cancel();
    // Serve 6 requests (list, claim, flash_begin, 2x flash_chunk, flash_commit).
    try sel.concurrent(.server, serveSession, .{ io, &server, "agent-host", key, &agent_state, 6 });
    try sel.concurrent(.client, struct {
        fn run(h: *[1]agent.Host, t: *[1]agent.Target, reg: *model.Registry) anyerror!void {
            agent.scanHosts(h, t, reg);
            var owner: u8 = 0;
            const chosen: model.Selection = .{
                .host_id = "agent-host",
                .probe_id = "jlink-a",
                .board_id = "fpb-ra8e1",
                .generation = reg.entries[0].?.generation,
            };
            try reg.reserve(&owner, chosen);
            var big: [wire.raw_chunk_bytes + 3548]u8 = @splat(0x5a);
            var out: [256]u8 = undefined;
            const reply = try reg.flash(&owner, chosen, &big, &out);
            try std.testing.expectEqualStrings("{\"flashed\":true,\"verified\":true,\"bytes\":19932}", reply);
            reg.release(&owner);
        }
    }.run, .{ &hosts, &targets, &local_reg });
    try (switch (try sel.await()) {
        .server => |r| r,
        .client => |r| r,
    });
    try (switch (try sel.await()) {
        .server => |r| r,
        .client => |r| r,
    });
    try std.testing.expectEqual(@as(usize, 1), log.flashes);
}
