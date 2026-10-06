//! The session client `ctl --connect` speaks through (RA8EMU-747): one
//! connection to a running `serve`, one call at a time.
const std = @import("std");
const proto = @import("../rpc/session_rpc.zig");
const Connection = @import("../rpc/socket_transport.zig").Connection;
const Spec = @import("serve_listen.zig").Spec;

const Env = proto.Client.Env;
const Incoming = proto.Client.Incoming;

/// How long ctl waits for any one answer before giving up.
const answer_wait_ms = 30_000;

pub const Client = struct {
    connection: Connection,
    rx: []u8,
    tx: []u8,
    client: proto.Client,
    /// The code of the last refusal, for the error line.
    refused: u16 = 0,

    /// Connect to `spec` and finish the handshake. Buffers come from
    /// `allocator`, which ctl runs as an arena.
    pub fn open(allocator: std.mem.Allocator, spec: Spec) !*Client {
        const self = try allocator.create(Client);
        self.* = .{
            .connection = switch (spec) {
                .unix => |path| try Connection.unix(path),
                .tcp => |address| try Connection.tcp(address),
            },
            .rx = try allocator.alloc(u8, 2 * Env.max_frame),
            .tx = try allocator.alloc(u8, Env.max_frame),
            .client = undefined,
        };
        self.client = proto.Client.init(self.connection.transport(), self.rx, proto.capabilities);
        try self.client.greet(self.tx);
        while (true) switch (try self.next()) {
            .ready => return self,
            else => {},
        };
    }

    pub fn close(self: *Client) void {
        self.connection.close();
    }

    /// The next frame from the server, or error.ServerSilent.
    fn next(self: *Client) !Incoming {
        const deadline = std.time.milliTimestamp() + answer_wait_ms;
        while (std.time.milliTimestamp() < deadline) {
            if (try self.client.poll(self.tx)) |incoming| return incoming;
            std.time.sleep(std.time.ns_per_ms);
        }
        return error.ServerSilent;
    }

    /// Call `method` and decode its `Reply`, skipping events on the way.
    /// A slice in the reply lives until the next call.
    pub fn call(self: *Client, comptime Reply: type, comptime Args: type, method: proto.Method, args: Args) !Reply {
        _ = try self.client.call(Args, @intFromEnum(method), args, 0, self.tx);
        while (true) switch (try self.next()) {
            .response => |response| switch (response.result) {
                .ok => |bytes| return try proto.decode(Reply, bytes),
                .err => |code| {
                    self.refused = @intFromEnum(code);
                    return error.Refused;
                },
            },
            else => {},
        };
    }

    /// The next stop event the server sends.
    pub fn stop(self: *Client) !proto.Stopped {
        while (true) switch (try self.next()) {
            .event => |event| if (event.topic == @intFromEnum(proto.Topic.stop)) {
                return try proto.decode(proto.Stopped, event.payload);
            },
            else => {},
        };
    }
};
