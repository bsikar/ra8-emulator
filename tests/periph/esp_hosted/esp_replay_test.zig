//! A C6 fetch recorded against a real loopback server replays offline,
//! byte for byte, and an unrecorded request fails (RA8EMU-560).
const std = @import("std");
const ra8 = @import("ra8");
const hosted = ra8.periph.esp_hosted;
const eth = hosted.eth;
const frame = hosted.frame;
const tape = hosted.tape;
const Bridge = hosted.net.Bridge;
const Queue = hosted.queue.Queue;

const request = "GET / HTTP/1.0\r\n\r\n";
const response = "HTTP/1.0 200 OK\r\nContent-Length: 8\r\n\r\nra8-tape";

const guest_route = eth.Route{
    .src_mac = hosted.station.mac,
    .dst_mac = hosted.station.bssid,
    .src_ip = hosted.dhcp.lease_ip,
    .dst_ip = hosted.dhcp.server_ip,
    .src_port = 40000,
    .dst_port = 0,
};

fn sendTcp(bridge: *Bridge, queue: *Queue, port: u16, seq: u32, ack: u32, flags: u8, payload: []const u8) !void {
    var bytes: [frame.max_payload]u8 = undefined;
    var route = guest_route;
    route.dst_port = port;
    const len = eth.tcpFrame(&bytes, route, seq, ack, flags, 1460, payload).?;
    try std.testing.expectEqual(hosted.net.Result.handled, bridge.forward(queue, bytes[0..len]));
}

fn waitSegment(bridge: *Bridge, queue: *Queue, out: *[frame.max_payload]u8) !eth.Tcp {
    for (0..2000) |_| {
        bridge.poll(queue);
        var hosted_frame: [frame.frame_size]u8 = undefined;
        if (queue.pop(&hosted_frame)) {
            const parsed = try frame.parse(&hosted_frame);
            @memcpy(out[0..parsed.payload.len], parsed.payload);
            return eth.tcp(eth.ipv4(out[0..parsed.payload.len]).?).?;
        }
        std.Thread.sleep(std.time.ns_per_ms);
    }
    return error.Timeout;
}

/// Opens a connection to `port`, sends `ask`, and gathers what comes back
/// until the host closes. Returns the reply length, or null on a reset.
fn fetch(bridge: *Bridge, queue: *Queue, port: u16, ask: []const u8, reply: []u8) !?usize {
    var bytes: [frame.max_payload]u8 = undefined;
    try sendTcp(bridge, queue, port, 100, 0, eth.TcpFlag.syn, &.{});
    const opened = try waitSegment(bridge, queue, &bytes);
    if (opened.flags & eth.TcpFlag.rst != 0) return null;
    var host_next = opened.seq +% 1;
    const guest_next: u32 = 101 + @as(u32, @intCast(ask.len));
    try sendTcp(bridge, queue, port, 101, host_next, eth.TcpFlag.ack, &.{});
    try sendTcp(bridge, queue, port, 101, host_next, eth.TcpFlag.psh | eth.TcpFlag.ack, ask);
    var len: usize = 0;
    while (true) {
        const segment = try waitSegment(bridge, queue, &bytes);
        if (segment.flags & eth.TcpFlag.rst != 0) return null;
        if (segment.data.len != 0 and segment.seq == host_next) {
            @memcpy(reply[len..][0..segment.data.len], segment.data);
            len += segment.data.len;
            host_next +%= @intCast(segment.data.len);
            try sendTcp(bridge, queue, port, guest_next, host_next, eth.TcpFlag.ack, &.{});
        }
        if (segment.flags & eth.TcpFlag.fin != 0) break;
    }
    try sendTcp(bridge, queue, port, guest_next, host_next +% 1, eth.TcpFlag.fin | eth.TcpFlag.ack, &.{});
    return len;
}

const Server = struct {
    server: *std.net.Server,
    failed: bool = false,

    fn run(self: *Server) void {
        self.serve() catch {
            self.failed = true;
        };
    }

    fn serve(self: *Server) !void {
        const connection = for (0..2000) |_| {
            break self.server.accept() catch |err| switch (err) {
                error.WouldBlock => {
                    std.Thread.sleep(std.time.ns_per_ms);
                    continue;
                },
                else => return err,
            };
        } else return error.Timeout;
        defer connection.stream.close();
        var got: [request.len]u8 = undefined;
        try connection.stream.reader().readNoEof(&got);
        if (!std.mem.eql(u8, &got, request)) return error.WrongRequest;
        try connection.stream.writeAll(response);
    }
};

/// Records one fetch against a live loopback server; returns its port.
fn record(path: []const u8, reply: []u8) !struct { port: u16, len: usize } {
    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    var server = try address.listen(.{ .reuse_address = true, .force_nonblocking = true });
    defer server.deinit();
    var host = Server{ .server = &server };
    const thread = try std.Thread.spawn(.{}, Server.run, .{&host});
    var bridge: Bridge = .{ .tape = try tape.Tape.open(path, .record) };
    defer bridge.deinit();
    var queue: Queue = .{};
    const port = server.listen_address.getPort();
    const len = (try fetch(&bridge, &queue, port, request, reply)).?;
    thread.join();
    try std.testing.expect(!host.failed);
    return .{ .port = port, .len = len };
}

test "a recorded fetch replays offline byte for byte" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = buf[0..try tmp.dir.realPathFile(std.testing.io, ".", &buf)];
    var live: [128]u8 = undefined;
    const recorded = try record(path, &live);
    try std.testing.expectEqualStrings(response, live[0..recorded.len]);

    var bridge: Bridge = .{ .tape = try tape.Tape.open(path, .replay) };
    defer bridge.deinit();
    var queue: Queue = .{};
    var replayed: [128]u8 = undefined;
    const len = (try fetch(&bridge, &queue, recorded.port, request, &replayed)).?;
    try std.testing.expectEqualSlices(u8, live[0..recorded.len], replayed[0..len]);
    try std.testing.expectEqual(@as(u32, 0), bridge.tape.missed());
}

test "replay resets a connection it has no recording for and counts the miss" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = buf[0..try tmp.dir.realPathFile(std.testing.io, ".", &buf)];
    var bridge: Bridge = .{ .tape = try tape.Tape.open(path, .replay) };
    defer bridge.deinit();
    var queue: Queue = .{};
    var reply: [128]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, null), try fetch(&bridge, &queue, 8080, request, &reply));
    try std.testing.expectEqual(@as(u32, 1), bridge.tape.missed());
}

test "replay refuses a request that differs from the recording" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = buf[0..try tmp.dir.realPathFile(std.testing.io, ".", &buf)];
    var live: [128]u8 = undefined;
    const recorded = try record(path, &live);

    var bridge: Bridge = .{ .tape = try tape.Tape.open(path, .replay) };
    defer bridge.deinit();
    var queue: Queue = .{};
    var reply: [128]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, null), try fetch(&bridge, &queue, recorded.port, "GET /x HTTP/1.0\r\n\r\n", &reply));
    try std.testing.expectEqual(@as(u32, 1), bridge.tape.missed());
}
