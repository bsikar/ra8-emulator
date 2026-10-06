//! Spawns `ra8_emulator serve --listen` on a Unix path and on an
//! ephemeral localhost TCP port and drives a session over each (RA8EMU-736).
const std = @import("std");
const ra8 = @import("ra8");
const test_paths = @import("test_paths");
const Connection = ra8.interfaces.rpc.socket.Connection;
const serve_peer = @import("serve_peer.zig");
const image_path = serve_peer.image_path;
const Term = std.process.Child.Term;

/// Start serve on `spec` and return it with the address it says it bound.
fn start(gpa: std.mem.Allocator, spec: []const u8, line: []u8) !struct { child: std.process.Child, bound: []const u8 } {
    var child = std.process.Child.init(&.{ test_paths.emulator, "serve", "--listen", spec, image_path }, gpa);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    errdefer _ = child.kill() catch {};
    const said = try child.stderr.?.reader().readUntilDelimiter(line, '\n');
    const prefix = "serve: listening on ";
    try std.testing.expect(std.mem.startsWith(u8, said, prefix));
    return .{ .child = child, .bound = said[prefix.len..] };
}

/// Drive one session over `connection`, hang up, then stop serve with SIGTERM.
fn session(gpa: std.mem.Allocator, child: *std.process.Child, connection: *Connection) !void {
    const peer = try serve_peer.Peer.init(gpa, connection.transport());
    defer peer.deinit();
    try peer.drive();
    connection.close();
    try std.testing.expectEqual(Term{ .Exited = 0 }, try child.kill());
}

test "serve --listen tcp::0 binds localhost, serves a client and exits 0 on SIGTERM" {
    const gpa = std.testing.allocator;
    var line: [128]u8 = undefined;
    var started = try start(gpa, "tcp::0", &line);
    try std.testing.expect(std.mem.startsWith(u8, started.bound, "tcp:127.0.0.1:"));
    const colon = std.mem.lastIndexOfScalar(u8, started.bound, ':').?;
    const port = try std.fmt.parseInt(u16, started.bound[colon + 1 ..], 10);
    var connection = try Connection.tcp(try std.net.Address.parseIp4("127.0.0.1", port));
    try session(gpa, &started.child, &connection);
}

test "serve --listen unix:PATH serves a client and removes the path on SIGTERM" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/serve.sock", .{tmp.sub_path});
    defer gpa.free(path);
    const spec = try std.fmt.allocPrint(gpa, "unix:{s}", .{path});
    defer gpa.free(spec);
    var line: [256]u8 = undefined;
    var started = try start(gpa, spec, &line);
    try std.testing.expectEqualStrings(spec, started.bound);
    var connection = try Connection.unix(path);
    try session(gpa, &started.child, &connection);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("serve.sock", .{}));
}

test "serve --listen with a bad spec prints its usage and exits 2" {
    const specs = [_][]const u8{ "tcp:nope", "tcp:host.example:1", "udp::1", "unix:" };
    for (specs) |spec| {
        const result = try std.process.Child.run(.{
            .allocator = std.testing.allocator,
            .argv = &.{ test_paths.emulator, "serve", "--listen", spec, image_path },
        });
        defer std.testing.allocator.free(result.stdout);
        defer std.testing.allocator.free(result.stderr);
        try std.testing.expectEqual(Term{ .Exited = 2 }, result.term);
        try std.testing.expectEqualStrings(ra8.core.serve_main.usage, result.stderr);
    }
}

test "listen specs: an empty host and localhost bind loopback, a bracketed v6 literal parses" {
    const Spec = ra8.core.serve_listen.Spec;
    const loopback = try std.net.Address.parseIp4("127.0.0.1", 7000);
    try std.testing.expect((try Spec.parse("tcp::7000")).tcp.eql(loopback));
    try std.testing.expect((try Spec.parse("tcp:localhost:7000")).tcp.eql(loopback));
    try std.testing.expect((try Spec.parse("tcp:[::1]:7000")).tcp.eql(try std.net.Address.parseIp6("::1", 7000)));
    try std.testing.expectEqualStrings("/tmp/s", (try Spec.parse("unix:/tmp/s")).unix);
    try std.testing.expectError(error.BadListen, Spec.parse("tcp::70000"));
}
