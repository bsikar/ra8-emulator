//! The host listener tests' shared helpers: one gdb client over the
//! session's loopback port pumped between frames, the framed call
//! shorthand, and the load-and-read pattern. Split out of the host
//! listener test file so the file stays small; both listener test
//! files import it.
const std = @import("std");
const ra8 = @import("ra8");
const serve_peer = @import("../cli/serve_peer.zig");
const listener_mod = ra8.rpc.host_listener;
const Connection = ra8.rpc.socket_transport.Connection;
const served_setup = ra8.rpc.served_setup;
const proto = ra8.rpc.session.rpc;

const image = serve_peer.image_path;

pub fn tempHome(gpa: std.mem.Allocator) ![]u8 {
    var prng = std.Random.DefaultPrng.init(@intCast(std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds()));
    const parent = if (@import("builtin").os.tag == .windows)
        try (std.process.Environ{ .block = .global }).getAlloc(gpa, "TEMP")
    else
        try gpa.dupe(u8, "/tmp");
    defer gpa.free(parent);
    const name = try std.fmt.allocPrint(gpa, "ra8_listener_{d}", .{prng.random().int(u64)});
    defer gpa.free(name);
    const path = try std.fs.path.join(gpa, &.{ parent, name });
    errdefer gpa.free(path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, path);
    return path;
}

pub fn envWithHome(gpa: std.mem.Allocator, home: []const u8) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(gpa);
    errdefer env.deinit();
    try env.put("HOME", home);
    return env;
}

pub const Gdb = struct {
    stream: std.Io.net.Stream,
    wire: ra8.gdb.rsp.packet.Reader,
    incoming: [0x1000]u8,
    reply_buf: [0x1000]u8,

    /// Fill in place: the reader holds the buffers' addresses.
    pub fn init(self: *Gdb, port: u16) !void {
        const ip = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        self.stream = try ip.connect(std.testing.io, .{ .mode = .stream });
        errdefer self.stream.close(std.testing.io);
        self.wire = ra8.gdb.rsp.packet.Reader.init(&self.incoming);
    }

    pub fn deinit(self: *Gdb) void {
        self.stream.close(std.testing.io);
    }

    /// Frame and write one request.
    pub fn send(self: *Gdb, payload: []const u8) !void {
        var framed: [0x1100]u8 = undefined;
        const bytes = try ra8.gdb.rsp.packet.frame(&framed, payload);
        ra8.host.sock.ready.sendAll(std.testing.io, self.stream.socket.handle, bytes, 1000) catch return error.Socket;
    }

    /// The next packet the stub sends, pumping the host between polls.
    pub fn reply(self: *Gdb, bound: *listener_mod.Listener) ![]const u8 {
        const fd = self.stream.socket.handle;
        const deadline = std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() + 10_000;
        while (std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() < deadline) {
            bound.pumpGdb();
            while (std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() < deadline and
                (ra8.host.sock.ready.wait(std.testing.io, fd, 0) catch return error.Socket).any())
            {
                var byte: [1]u8 = undefined;
                const got = ra8.host.sock.ready.takeByte(std.testing.io, fd, &byte, false) orelse return error.Socket;
                if (got == 0) return error.Closed;
                if (self.wire.push(byte[0])) |event| switch (event) {
                    .packet => |packet| {
                        @memcpy(self.reply_buf[0..packet.len], packet);
                        return self.reply_buf[0..packet.len];
                    },
                    else => {},
                };
            }
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
        }
        return error.NoReply;
    }

    /// The pc as gdb reads it: register 15 through the `p` packet. rsp
    /// sends a register's bytes in target order, hex-encoded.
    pub fn pc(self: *Gdb, bound: *listener_mod.Listener) !u32 {
        try self.send("pf");
        const hex = try self.reply(bound);
        if (hex.len < 8) return error.ShortReply;
        var bytes: [4]u8 = undefined;
        _ = std.fmt.hexToBytes(&bytes, hex[0..8]) catch return error.BadHex;
        return std.mem.readInt(u32, &bytes, .little);
    }
};

/// Fill the real peer queue and prove even a small reply meets backpressure.
pub fn blockReply(stream: std.Io.net.Stream, peer: std.Io.net.Stream) !void {
    const io = std.testing.io;
    if (@import("builtin").os.tag != .windows) {
        const size: c_int = 4096;
        try std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, std.mem.asBytes(&size));
        try std.posix.setsockopt(peer.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, std.mem.asBytes(&size));
    }
    const bytes: [64 * 1024]u8 = @splat('g');
    var chunk: []const u8 = &bytes;
    const deadline = std.Io.Timestamp.now(io, .awake).toMilliseconds() + 2000;
    while (std.Io.Timestamp.now(io, .awake).toMilliseconds() < deadline) {
        ra8.host.sock.ready.sendAll(io, stream.socket.handle, chunk, 20) catch |err| {
            try std.testing.expectEqual(error.Timeout, err);
            if (chunk.len == 1) return;
            chunk = "g";
        };
    }
    return error.Timeout;
}
/// A monitor command as the wire sees it: qRcmd, plus the hex text.
pub fn monitorHex(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = try gpa.alloc(u8, "qRcmd,".len + text.len * 2);
    @memcpy(out[0.."qRcmd,".len], "qRcmd,");
    const hex_chars = "0123456789abcdef";
    for (text, 0..) |byte, at| {
        out["qRcmd,".len + at * 2] = hex_chars[byte >> 4];
        out["qRcmd,".len + at * 2 + 1] = hex_chars[byte & 0xf];
    }
    return out;
}

/// The next frame from the server, serving the listener between polls.
pub fn next(peer: *serve_peer.Peer, bound: *listener_mod.Listener, context: *listener_mod.served.Context, tx: []u8) !proto.Client.Incoming {
    const deadline = std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() + 10_000;
    while (std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() < deadline) {
        if (try peer.client.poll(peer.tx)) |incoming| return incoming;
        try bound.answer(context, tx);
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.ServerSilent;
}

/// One call, its reply taken off the wire through `next`.
pub fn call(peer: *serve_peer.Peer, bound: *listener_mod.Listener, context: *listener_mod.served.Context, tx: []u8, comptime Reply: type, comptime Args: type, method: proto.Method, args: Args) !Reply {
    _ = try peer.client.call(Args, @backingInt(method), args, 0, peer.tx);
    while (true) switch (try next(peer, bound, context, tx)) {
        .response => |response| return switch (response.result) {
            .ok => |bytes| try proto.decode(Reply, bytes),
            .err => error.Refused,
        },
        else => {},
    };
}

/// Load the fixture over the wire, run, pause and read pc.
pub fn loadAndRead(peer: *serve_peer.Peer, bound: *listener_mod.Listener, context: *listener_mod.served.Context, tx: []u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, image, peer.gpa, .limited(1 << 20));
    defer peer.gpa.free(bytes);
    _ = try call(peer, bound, context, tx, proto.Ack, proto.Load, .load, .{ .core = .cpu0, .image = bytes });
    _ = try call(peer, bound, context, tx, proto.Ack, proto.Run, .run, .{ .core = .cpu0, .mode = .cont, .budget = 1000 });
    _ = try call(peer, bound, context, tx, proto.Ack, proto.CoreOnly, .pause, .{ .core = .cpu0 });
    const pc = try call(peer, bound, context, tx, proto.U32, proto.ReadRegister, .read_register, .{ .core = .cpu0, .register = .pc });
    try std.testing.expect(pc.value != 0);
}
