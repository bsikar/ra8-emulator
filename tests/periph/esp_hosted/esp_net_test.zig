//! Real loopback proof for the C6 TCP and UDP host bridge.
const std = @import("std");
const ra8 = @import("ra8");
const hosted = ra8.periph.esp_hosted;
const eth = hosted.eth;
const frame = hosted.frame;
const Bridge = hosted.net.Bridge;
const Queue = hosted.queue.Queue;

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

fn sendUdp(bridge: *Bridge, queue: *Queue, port: u16, payload: []const u8) !void {
    var bytes: [frame.max_payload]u8 = undefined;
    var route = guest_route;
    route.dst_port = port;
    const len = eth.udpFrame(&bytes, route, payload).?;
    try std.testing.expectEqual(hosted.net.Result.handled, bridge.forward(queue, bytes[0..len]));
}

fn popEthernet(queue: *Queue, out: *[frame.max_payload]u8) ?[]const u8 {
    var hosted_frame: [frame.frame_size]u8 = undefined;
    if (!queue.pop(&hosted_frame)) return null;
    const parsed = frame.parse(&hosted_frame) catch return null;
    @memcpy(out[0..parsed.payload.len], parsed.payload);
    return out[0..parsed.payload.len];
}

fn waitFrame(bridge: *Bridge, queue: *Queue, out: *[frame.max_payload]u8) ![]const u8 {
    for (0..2000) |_| {
        bridge.poll(queue);
        if (popEthernet(queue, out)) |bytes| return bytes;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    return error.Timeout;
}

const TcpHost = struct {
    server: *std.net.Server,
    request: [64]u8 = undefined,
    request_len: usize = 0,
    failed: bool = false,
    stop: std.atomic.Value(bool) = .init(false),

    fn run(self: *TcpHost) void {
        self.serve() catch {
            self.failed = true;
        };
    }

    fn serve(self: *TcpHost) !void {
        const connection = while (!self.stop.load(.acquire)) {
            break self.server.accept() catch |err| switch (err) {
                error.WouldBlock => {
                    std.Thread.sleep(std.time.ns_per_ms);
                    continue;
                },
                else => return err,
            };
        } else return;
        defer connection.stream.close();
        const expected = "GET / HTTP/1.0\r\n\r\n";
        try connection.stream.reader().readNoEof(self.request[0..expected.len]);
        self.request_len = expected.len;
        try connection.stream.writeAll("HTTP/1.0 200 OK\r\nContent-Length: 8\r\n\r\nra8-loop");
    }
};

test "firmware TCP frames fetch an exact page from a real loopback server" {
    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    var server = try address.listen(.{ .reuse_address = true, .force_nonblocking = true });
    defer server.deinit();
    var host = TcpHost{ .server = &server };
    const thread = try std.Thread.spawn(.{}, TcpHost.run, .{&host});
    var joined = false;
    defer if (!joined) thread.join();
    defer host.stop.store(true, .release);

    var bridge: Bridge = .{};
    defer bridge.deinit();
    var queue: Queue = .{};
    const port = server.listen_address.getPort();
    try sendTcp(&bridge, &queue, port, 100, 0, eth.TcpFlag.syn, &.{});
    var bytes: [frame.max_payload]u8 = undefined;
    const syn_reply = try waitFrame(&bridge, &queue, &bytes);
    const syn_ack = eth.tcp(eth.ipv4(syn_reply).?).?;
    try std.testing.expectEqual(eth.TcpFlag.syn | eth.TcpFlag.ack, syn_ack.flags);
    try std.testing.expectEqual(@as(u32, 101), syn_ack.ack);
    const server_seq = syn_ack.seq +% 1;

    try sendTcp(&bridge, &queue, port, 101, server_seq, eth.TcpFlag.ack, &.{});
    const request = "GET / HTTP/1.0\r\n\r\n";
    try sendTcp(&bridge, &queue, port, 101, server_seq, eth.TcpFlag.psh | eth.TcpFlag.ack, request);
    _ = popEthernet(&queue, &bytes);

    const expected_response = "HTTP/1.0 200 OK\r\nContent-Length: 8\r\n\r\nra8-loop";
    var response: [expected_response.len]u8 = undefined;
    var response_len: usize = 0;
    var next_server = server_seq;
    while (response_len < response.len) {
        const incoming = try waitFrame(&bridge, &queue, &bytes);
        const segment = eth.tcp(eth.ipv4(incoming).?).?;
        if (segment.data.len == 0) continue;
        try std.testing.expectEqual(next_server, segment.seq);
        const take = @min(segment.data.len, response.len - response_len);
        @memcpy(response[response_len..][0..take], segment.data[0..take]);
        response_len += take;
        next_server +%= @intCast(segment.data.len);
        try sendTcp(&bridge, &queue, port, 101 + request.len, next_server, eth.TcpFlag.ack, &.{});
    }
    thread.join();
    joined = true;
    try std.testing.expectEqualSlices(u8, expected_response, &response);
    try std.testing.expect(!host.failed);
    try std.testing.expectEqualSlices(u8, request, host.request[0..host.request_len]);

    try sendTcp(&bridge, &queue, port, 101 + request.len, next_server, eth.TcpFlag.fin | eth.TcpFlag.ack, &.{});
    _ = try waitFrame(&bridge, &queue, &bytes);
}

const UdpHost = struct {
    fd: std.posix.socket_t,
    got: [32]u8 = undefined,
    got_len: usize = 0,
    failed: bool = false,
    stop: std.atomic.Value(bool) = .init(false),

    fn run(self: *UdpHost) void {
        self.echo() catch {
            self.failed = true;
        };
    }

    fn echo(self: *UdpHost) !void {
        var source: std.net.Address = undefined;
        var source_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
        while (!self.stop.load(.acquire)) {
            self.got_len = std.posix.recvfrom(self.fd, &self.got, 0, &source.any, &source_len) catch |err| switch (err) {
                error.WouldBlock => {
                    std.Thread.sleep(std.time.ns_per_ms);
                    continue;
                },
                else => return err,
            };
            _ = try std.posix.sendto(self.fd, self.got[0..self.got_len], 0, &source.any, source_len);
            return;
        }
    }
};

test "firmware UDP frames exchange a datagram with a real loopback socket" {
    const fd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC, 0);
    defer std.posix.close(fd);
    var address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    try std.posix.bind(fd, &address.any, address.getOsSockLen());
    var address_len = address.getOsSockLen();
    try std.posix.getsockname(fd, &address.any, &address_len);
    var host = UdpHost{ .fd = fd };
    const thread = try std.Thread.spawn(.{}, UdpHost.run, .{&host});
    var joined = false;
    defer if (!joined) thread.join();
    defer host.stop.store(true, .release);

    var bridge: Bridge = .{};
    defer bridge.deinit();
    var queue: Queue = .{};
    try sendUdp(&bridge, &queue, address.getPort(), "ra8-udp");
    var bytes: [frame.max_payload]u8 = undefined;
    const incoming = try waitFrame(&bridge, &queue, &bytes);
    thread.join();
    joined = true;
    try std.testing.expectEqualSlices(u8, "ra8-udp", eth.udp(incoming).?.data);
    try std.testing.expectEqualSlices(u8, "ra8-udp", host.got[0..host.got_len]);
    try std.testing.expect(!host.failed);
}
