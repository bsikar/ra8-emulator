//! Tests for src/periph/esp_hosted/esp_eth.zig.
const std = @import("std");
const ra8 = @import("ra8");
const eth = ra8.periph.esp_hosted.eth;

const route: eth.Route = .{
    .src_mac = .{ 1, 2, 3, 4, 5, 6 },
    .dst_mac = .{0xFF} ** 6,
    .src_ip = .{ 10, 0, 0, 1 },
    .dst_ip = .{ 10, 0, 0, 2 },
    .src_port = 68,
    .dst_port = 67,
};

fn sample(buf: []u8) usize {
    @memcpy(buf[eth.headers..][0..5], "hello");
    return eth.wrap(buf, route, 5);
}

test "a wrapped datagram reads back with its ports and payload" {
    var buf: [64]u8 = undefined;
    const len = sample(&buf);
    try std.testing.expectEqual(eth.headers + 5, len);
    const got = eth.udp(buf[0..len]).?;
    try std.testing.expectEqual(@as(u16, 68), got.src_port);
    try std.testing.expectEqual(@as(u16, 67), got.dst_port);
    try std.testing.expectEqualSlices(u8, "hello", got.data);
}

test "the IPv4 header checksum verifies" {
    var buf: [64]u8 = undefined;
    _ = sample(&buf);
    const ip = buf[eth.eth_header..][0..eth.ip_header];
    try std.testing.expectEqual(@as(u16, 0), eth.fold(eth.sum(0, ip)));
}

test "the UDP checksum verifies over the pseudo header" {
    var buf: [64]u8 = undefined;
    const len = sample(&buf);
    const datagram = buf[eth.eth_header + eth.ip_header .. len];
    var acc = eth.sum(0, &route.src_ip);
    acc = eth.sum(acc, &route.dst_ip);
    acc += eth.proto_udp + @as(u32, @intCast(datagram.len));
    try std.testing.expectEqual(@as(u16, 0), eth.fold(eth.sum(acc, datagram)));
}

test "frames that are not UDP over IPv4 are not read" {
    var buf: [64]u8 = undefined;
    const len = sample(&buf);
    var arp = buf;
    arp[12] = 0x08;
    arp[13] = 0x06;
    try std.testing.expect(eth.udp(arp[0..len]) == null);
    var tcp = buf;
    tcp[eth.eth_header + 9] = 6;
    try std.testing.expect(eth.udp(tcp[0..len]) == null);
    try std.testing.expect(eth.udp(buf[0..20]) == null);
}
