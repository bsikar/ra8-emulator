//! Bounded host UDP flows for the ESP32-C6 station bridge.
const std = @import("std");
const dhcp = @import("esp_dhcp.zig");
const eth = @import("esp_eth.zig");
const frame = @import("esp_frame.zig");
const Queue = @import("esp_queue.zig").Queue;

pub const capacity: usize = 8;
const invalid_socket: std.posix.socket_t = -1;

const Key = struct {
    src_ip: [4]u8,
    dst_ip: [4]u8,
    src_port: u16,
    dst_port: u16,

    fn eql(a: Key, b: Key) bool {
        return a.src_port == b.src_port and a.dst_port == b.dst_port and
            std.mem.eql(u8, &a.src_ip, &b.src_ip) and std.mem.eql(u8, &a.dst_ip, &b.dst_ip);
    }
};

const Flow = struct {
    used: bool = false,
    fd: std.posix.socket_t = invalid_socket,
    key: Key = undefined,
    route: eth.Route = undefined,
    generation: u64 = 0,
    pending: [eth.udp_payload_max]u8 = undefined,
    pending_len: usize = 0,

    fn close(self: *Flow) void {
        if (self.fd != invalid_socket) std.posix.close(self.fd);
        self.* = .{};
    }
};

pub const Bridge = struct {
    flows: [capacity]Flow = [_]Flow{.{}} ** capacity,
    generation: u64 = 0,
    cursor: usize = 0,

    pub fn deinit(self: *Bridge) void {
        for (&self.flows) |*flow| flow.close();
        self.generation = 0;
        self.cursor = 0;
    }
    pub fn active(self: *const Bridge) bool {
        for (self.flows) |flow| if (flow.used) return true;
        return false;
    }

    pub fn forward(self: *Bridge, ip: eth.Ipv4, datagram: eth.Udp) void {
        const key = makeKey(ip, datagram.src_port, datagram.dst_port);
        const index = self.find(key) orelse self.allocate(key, replyRoute(ip, datagram.src_port, datagram.dst_port)) orelse return;
        const flow = &self.flows[index];
        if (flow.pending_len != 0 or datagram.data.len > flow.pending.len) return;
        const sent = std.posix.send(flow.fd, datagram.data, 0) catch |err| switch (err) {
            error.WouldBlock => {
                @memcpy(flow.pending[0..datagram.data.len], datagram.data);
                flow.pending_len = datagram.data.len;
                return;
            },
            else => {
                flow.close();
                return;
            },
        };
        if (sent == datagram.data.len) self.touch(flow) else flow.close();
    }

    pub fn poll(self: *Bridge, queue: *Queue) void {
        for (0..capacity) |step| self.pollOne(queue, (self.cursor + step) % capacity);
        self.cursor = (self.cursor + 1) % capacity;
    }

    fn pollOne(self: *Bridge, queue: *Queue, index: usize) void {
        const flow = &self.flows[index];
        if (!flow.used) return;
        if (flow.pending_len != 0) {
            const sent = std.posix.send(flow.fd, flow.pending[0..flow.pending_len], 0) catch |err| switch (err) {
                error.WouldBlock => return,
                else => {
                    flow.close();
                    return;
                },
            };
            if (sent != flow.pending_len) {
                flow.close();
                return;
            }
            flow.pending_len = 0;
            self.touch(flow);
            return;
        }
        if (queue.len >= 2) return;
        var payload: [eth.udp_payload_max + 1]u8 = undefined;
        const got = std.posix.recv(flow.fd, &payload, std.posix.MSG.TRUNC) catch |err| switch (err) {
            error.WouldBlock => return,
            else => {
                flow.close();
                return;
            },
        };
        if (got > eth.udp_payload_max) return;
        var ethernet: [frame.max_payload]u8 = undefined;
        const len = eth.udpFrame(&ethernet, flow.route, payload[0..got]) orelse return;
        if (queueEthernet(queue, ethernet[0..len])) self.touch(flow);
    }

    fn allocate(self: *Bridge, key: Key, route: eth.Route) ?usize {
        var index: usize = 0;
        var oldest: u64 = std.math.maxInt(u64);
        for (&self.flows, 0..) |*flow, i| {
            if (!flow.used) {
                index = i;
                break;
            }
            if (flow.generation < oldest) {
                oldest = flow.generation;
                index = i;
            }
        }
        const flow = &self.flows[index];
        if (flow.used) flow.close();
        const fd = openSocket() catch return null;
        const address = hostAddress(key.dst_ip, key.dst_port);
        std.posix.connect(fd, &address.any, address.getOsSockLen()) catch {
            std.posix.close(fd);
            return null;
        };
        flow.* = .{ .used = true, .fd = fd, .key = key, .route = route };
        self.touch(flow);
        return index;
    }

    fn touch(self: *Bridge, flow: *Flow) void {
        self.generation +%= 1;
        flow.generation = self.generation;
    }

    fn find(self: *Bridge, key: Key) ?usize {
        for (&self.flows, 0..) |*flow, index| if (flow.used and flow.key.eql(key)) return index;
        return null;
    }
};

fn openSocket() !std.posix.socket_t {
    return std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC, 0);
}

fn hostAddress(destination: [4]u8, port: u16) std.net.Address {
    const host = if (std.mem.eql(u8, &destination, &dhcp.server_ip)) [4]u8{ 127, 0, 0, 1 } else destination;
    return std.net.Address.initIp4(host, port);
}

fn makeKey(ip: eth.Ipv4, src_port: u16, dst_port: u16) Key {
    return .{ .src_ip = ip.src_ip, .dst_ip = ip.dst_ip, .src_port = src_port, .dst_port = dst_port };
}

fn replyRoute(ip: eth.Ipv4, src_port: u16, dst_port: u16) eth.Route {
    return .{
        .src_mac = ip.dst_mac,
        .dst_mac = ip.src_mac,
        .src_ip = ip.dst_ip,
        .dst_ip = ip.src_ip,
        .src_port = dst_port,
        .dst_port = src_port,
    };
}

fn queueEthernet(queue: *Queue, ethernet: []const u8) bool {
    var hosted: [frame.frame_size]u8 = undefined;
    frame.build(&hosted, .{ .interface = .sta, .if_num = 0 }, ethernet) catch return false;
    return queue.push(&hosted);
}
