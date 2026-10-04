//! Ethernet II, IPv4 and UDP framing for the C6 station data path.
//!
//! esp-hosted carries the station's traffic as raw Ethernet frames on the
//! sta interface. The model only needs to read and write UDP datagrams over
//! IPv4 (the DHCP exchange), so this is that and nothing more.
const std = @import("std");

pub const eth_header: usize = 14;
pub const ip_header: usize = 20;
pub const udp_header: usize = 8;
/// Bytes before a UDP payload in a frame `wrap` writes.
pub const headers: usize = eth_header + ip_header + udp_header;
pub const ethertype_ipv4: u16 = 0x0800;
pub const proto_udp: u8 = 17;

/// A UDP datagram read out of an Ethernet frame.
pub const Udp = struct { src_port: u16, dst_port: u16, data: []const u8 };

/// The UDP datagram an Ethernet frame carries, or null for anything else.
pub fn udp(bytes: []const u8) ?Udp {
    if (bytes.len < headers) return null;
    if (be16(bytes[12..14]) != ethertype_ipv4) return null;
    const ip = bytes[eth_header..];
    if (ip[0] >> 4 != 4 or ip[9] != proto_udp) return null;
    const ihl: usize = @as(usize, ip[0] & 0xF) * 4;
    const total: usize = be16(ip[2..4]);
    if (ihl < ip_header or total < ihl + udp_header or total > ip.len) return null;
    const u = ip[ihl..total];
    const len: usize = be16(u[4..6]);
    if (len < udp_header or len > u.len) return null;
    return .{ .src_port = be16(u[0..2]), .dst_port = be16(u[2..4]), .data = u[udp_header..len] };
}

/// Addresses and ports for a datagram `wrap` frames.
pub const Route = struct {
    src_mac: [6]u8,
    dst_mac: [6]u8,
    src_ip: [4]u8,
    dst_ip: [4]u8,
    src_port: u16,
    dst_port: u16,
};

/// Writes the Ethernet, IPv4 and UDP headers in front of the `data_len`
/// payload already at out[headers..] and returns the frame length.
pub fn wrap(out: []u8, route: Route, data_len: usize) usize {
    const udp_len = udp_header + data_len;
    const ip_len = ip_header + udp_len;
    @memcpy(out[0..6], &route.dst_mac);
    @memcpy(out[6..12], &route.src_mac);
    std.mem.writeInt(u16, out[12..14], ethertype_ipv4, .big);
    const ip = out[eth_header..][0..ip_header];
    @memset(ip, 0);
    ip[0] = 0x45;
    std.mem.writeInt(u16, ip[2..4], @intCast(ip_len), .big);
    ip[8] = 64;
    ip[9] = proto_udp;
    @memcpy(ip[12..16], &route.src_ip);
    @memcpy(ip[16..20], &route.dst_ip);
    std.mem.writeInt(u16, ip[10..12], fold(sum(0, ip)), .big);
    const u = out[eth_header + ip_header ..][0..udp_len];
    std.mem.writeInt(u16, u[0..2], route.src_port, .big);
    std.mem.writeInt(u16, u[2..4], route.dst_port, .big);
    std.mem.writeInt(u16, u[4..6], @intCast(udp_len), .big);
    std.mem.writeInt(u16, u[6..8], 0, .big);
    std.mem.writeInt(u16, u[6..8], udpChecksum(route, u), .big);
    return eth_header + ip_len;
}

/// The UDP checksum over the IPv4 pseudo header; 0 is sent as 0xFFFF.
fn udpChecksum(route: Route, datagram: []const u8) u16 {
    var acc = sum(0, &route.src_ip);
    acc = sum(acc, &route.dst_ip);
    acc += proto_udp + @as(u32, @intCast(datagram.len));
    const c = fold(sum(acc, datagram));
    return if (c == 0) 0xFFFF else c;
}

/// Adds `bytes` as big-endian 16-bit words to a one's-complement sum.
pub fn sum(start: u32, bytes: []const u8) u32 {
    var acc = start;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) acc += be16(bytes[i..][0..2]);
    if (bytes.len % 2 == 1) acc += @as(u32, bytes[bytes.len - 1]) << 8;
    return acc;
}

/// Folds a one's-complement sum to 16 bits and inverts it.
pub fn fold(start: u32) u16 {
    var acc = start;
    while (acc >> 16 != 0) acc = (acc & 0xFFFF) + (acc >> 16);
    return ~@as(u16, @truncate(acc));
}

fn be16(bytes: *const [2]u8) u16 {
    return std.mem.readInt(u16, bytes, .big);
}
