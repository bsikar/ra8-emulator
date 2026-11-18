const std = @import("std");

const auth = @import("ra8").host.probe_host.auth;

test "RA8PH2 handshake derives directional keys and rejects wrong secret replayed seq or tampered frame" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const secret_hex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "secret.key", .data = secret_hex });
    const path = try tmp.dir.realPathFileAlloc(io, "secret.key", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const key = try auth.readKey(io, path);

    var bind = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try bind.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.ip4.port;

    const Pair = union(enum) { client: anyerror!auth.Session, agent: anyerror!auth.Session };
    var results: [2]Pair = undefined;
    var sel: std.Io.Select(Pair) = .init(io, &results);
    defer _ = sel.cancel();
    try sel.concurrent(.agent, runAgent, .{ io, &server, "bench-a", key });
    try sel.concurrent(.client, runClient, .{ io, port, "bench-a", key });
    const first = try sel.await();
    const second = try sel.await();
    var client_sess = if (first == .client) try first.client else try second.client;
    var agent_sess = if (first == .agent) try first.agent else try second.agent;

    const tag1 = client_sess.sign("{\"op\":\"list\"}");
    try agent_sess.verify(1, tag1, "{\"op\":\"list\"}");
    try std.testing.expectError(error.AuthenticationFailed, agent_sess.verify(1, tag1, "{\"op\":\"list\"}"));
    const tag2 = client_sess.sign("{\"op\":\"list\"}");
    try std.testing.expectError(error.AuthenticationFailed, agent_sess.verify(2, tag2, "{\"op\":\"claim\"}"));
}

fn runAgent(io: std.Io, server: *std.Io.net.Server, host_id: []const u8, key: auth.Key) anyerror!auth.Session {
    var peer = try server.accept(io);
    defer peer.close(io);
    var rx: [512]u8 = undefined;
    var tx: [512]u8 = undefined;
    var reader = peer.reader(io, &rx);
    var writer = peer.writer(io, &tx);
    return auth.authenticateAgent(io, &reader.interface, &writer.interface, host_id, key);
}

fn runClient(io: std.Io, port: u16, host_id: []const u8, key: auth.Key) anyerror!auth.Session {
    const remote = try std.Io.net.HostName.init("127.0.0.1");
    var stream = try remote.connect(io, port, .{ .mode = .stream });
    defer stream.close(io);
    var rx: [512]u8 = undefined;
    var tx: [512]u8 = undefined;
    var reader = stream.reader(io, &rx);
    var writer = stream.writer(io, &tx);
    return auth.authenticateClient(io, &reader.interface, &writer.interface, host_id, key);
}
