const std = @import("std");

const auth = @import("ra8").host.probe_host.auth;

test "probe-host mutual HMAC handshake succeeds with matching key and host_id and rejects mismatches" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const secret_hex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "secret.key", .data = secret_hex });
    try tmp.dir.writeFile(io, .{ .sub_path = "short.key", .data = "0123\n" });
    const path = try tmp.dir.realPathFileAlloc(io, "secret.key", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const bad_path = try tmp.dir.realPathFileAlloc(io, "short.key", std.testing.allocator);
    defer std.testing.allocator.free(bad_path);

    const key = try auth.readKey(io, path);
    try std.testing.expectError(error.InvalidSecret, auth.readKey(io, bad_path));

    var bind = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try bind.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.ip4.port;

    const Pair = union(enum) { client: anyerror!void, agent: anyerror!void };
    var results: [2]Pair = undefined;
    var sel: std.Io.Select(Pair) = .init(io, &results);
    defer _ = sel.cancel();
    try sel.concurrent(.agent, runAgent, .{ io, &server, "bench-a", key });
    try sel.concurrent(.client, runClient, .{ io, port, "bench-a", key });
    try (switch (try sel.await()) {
        .client => |r| r,
        .agent => |r| r,
    });
    try (switch (try sel.await()) {
        .client => |r| r,
        .agent => |r| r,
    });

    var wrong_key = key;
    wrong_key[0] ^= 0xff;
    var results2: [2]Pair = undefined;
    var sel2: std.Io.Select(Pair) = .init(io, &results2);
    defer _ = sel2.cancel();
    try sel2.concurrent(.agent, runAgent, .{ io, &server, "bench-a", key });
    try sel2.concurrent(.client, runClient, .{ io, port, "bench-a", wrong_key });
    const a = try sel2.await();
    const b = try sel2.await();
    const client_res = if (a == .client) a.client else b.client;
    try std.testing.expectError(error.AuthenticationFailed, client_res);
}

fn runAgent(io: std.Io, server: *std.Io.net.Server, host_id: []const u8, key: auth.Key) anyerror!void {
    var peer = try server.accept(io);
    defer peer.close(io);
    var rx: [512]u8 = undefined;
    var tx: [512]u8 = undefined;
    var reader = peer.reader(io, &rx);
    var writer = peer.writer(io, &tx);
    return auth.authenticateAgent(io, &reader.interface, &writer.interface, host_id, key);
}

fn runClient(io: std.Io, port: u16, host_id: []const u8, key: auth.Key) anyerror!void {
    const remote = try std.Io.net.HostName.init("127.0.0.1");
    var stream = try remote.connect(io, port, .{ .mode = .stream });
    defer stream.close(io);
    var rx: [512]u8 = undefined;
    var tx: [512]u8 = undefined;
    var reader = stream.reader(io, &rx);
    var writer = stream.writer(io, &tx);
    return auth.authenticateClient(io, &reader.interface, &writer.interface, host_id, key);
}
