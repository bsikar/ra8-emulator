//! Address and route translation between guest packets and host sockets.
const dhcp = @import("dhcp.zig");
const eth = @import("eth.zig");
const Key = @import("tcp_flow.zig").Key;
const std = @import("std");

pub fn hostAddress(destination: [4]u8, port: u16) std.Io.net.Ip4Address {
    const host = if (std.mem.eql(u8, &destination, &dhcp.server_ip)) [4]u8{ 127, 0, 0, 1 } else destination;
    return .{ .bytes = host, .port = port };
}

pub fn makeKey(ip: eth.Ipv4, src_port: u16, dst_port: u16) Key {
    return .{ .src_ip = ip.src_ip, .dst_ip = ip.dst_ip, .src_port = src_port, .dst_port = dst_port };
}

pub fn replyRoute(ip: eth.Ipv4, src_port: u16, dst_port: u16) eth.Route {
    return .{
        .src_mac = ip.dst_mac,
        .dst_mac = ip.src_mac,
        .src_ip = ip.dst_ip,
        .dst_ip = ip.src_ip,
        .src_port = dst_port,
        .dst_port = src_port,
    };
}
