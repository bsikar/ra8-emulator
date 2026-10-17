//! The GUI's connection to a session (RA8EMU-751): a session_rpc client on
//! any byte transport, plus the connection state the shell's status line
//! shows. Nothing blocks; the shell calls `pump` once a frame.
const std = @import("std");
const rpc = @import("ra8_rpc_wire");
const proto = @import("ra8_rpc").session.rpc;
const Stdio = @import("ra8_rpc").stdio_transport.Stdio;
const local_native_link = @import("local_native_link.zig");

pub const Env = proto.Client.Env;

/// Why a connection stopped being usable.
pub const Failure = enum {
    /// The session speaks another protocol version.
    version_mismatch,
    /// The session refused the handshake for another reason.
    rejected,
    /// The session went away: the child exited or the socket closed.
    ended,
    /// The session sent something this client cannot read.
    garbled,

    /// The line the status bar shows.
    pub fn message(self: Failure) []const u8 {
        return switch (self) {
            .version_mismatch => "the session speaks another protocol version",
            .rejected => "the session refused the connection",
            .ended => "the session exited",
            .garbled => "the session sent a frame this client cannot read",
        };
    }
};

pub const State = union(enum) {
    connecting,
    connected: struct { version: u16, caps: u32 },
    failed: Failure,
    closed,
};

/// What one pump took off the wire.
pub const Arrival = union(enum) {
    response: struct { id: u32, result: Env.Result },
    event: Env.Event,
};

fn classify(err: proto.Error) Failure {
    return switch (err) {
        error.VersionMismatch => .version_mismatch,
        error.BadMagic, error.Rejected, error.NotReady => .rejected,
        error.LinkDown => .ended,
        else => .garbled,
    };
}

/// A client on one session. It must not move once opened: the client
/// reaches the wire through a pointer to it.
pub const Link = struct {
    inner: rpc.Transport = undefined,
    client: proto.Client = undefined,
    tx: []u8 = &.{},
    state: State = .connecting,
    /// Set when the link is native: `send` queues into the mailbox and
    /// `pump` takes its ring; no wire is involved.
    native: ?*local_native_link.Native = null,

    /// Greet the session on `wire`. `rx` (2 * Env.max_frame bytes) and `tx`
    /// (Env.max_frame bytes) must outlive the link.
    pub fn open(self: *Link, wire: rpc.Transport, rx: []u8, tx: []u8) void {
        self.* = .{ .inner = wire, .client = undefined, .tx = tx };
        self.client = proto.Client.init(self.watched(), rx, proto.capabilities);
        self.client.greet(tx) catch |err| self.fail(err);
    }

    /// Go native: the link's typed requests wait in `native`'s mailbox
    /// for the session's thread, and its pump takes that queue's arrivals.
    /// The link reports itself connected at once; there is no greeting.
    pub fn openNative(self: *Link, native: *local_native_link.Native) void {
        // The local host always pumps the session's plane, so it carries
        // the transport capability (bit 15, RA8EMU-1196) beside the rest.
        self.* = .{ .native = native, .state = .{ .connected = .{ .version = proto.protocol_version, .caps = proto.capabilities | proto.transport_cap } } };
    }

    /// The session's capability bits, or 0 while not connected.
    pub fn caps(self: *Link) u32 {
        return if (self.state == .connected) self.state.connected.caps else 0;
    }

    /// Take at most one frame off the wire and update the state. Returns
    /// the response or event it carried; a slice in it lives until the
    /// next pump.
    pub fn pump(self: *Link) ?Arrival {
        switch (self.state) {
            .failed, .closed => return null,
            else => {},
        }
        if (self.native) |n| {
            const got = (n.pump() catch |err| {
                self.fail(err);
                return null;
            }) orelse return null;
            return switch (got) {
                .response => |r| .{ .response = .{ .id = r.id, .result = r.result } },
                .event => |e| .{ .event = e },
            };
        }
        const got = (self.client.poll(self.tx) catch |err| {
            self.fail(err);
            return null;
        }) orelse return null;
        switch (got) {
            .ready => |offered| {
                self.state = .{ .connected = .{ .version = proto.protocol_version, .caps = offered } };
                return null;
            },
            .response => |response| return .{ .response = .{ .id = response.id, .result = response.result } },
            .event => |event| return .{ .event = event },
        }
    }

    /// Send a request and return its id; the response comes back by pump.
    /// A full pending table is back-pressure, not a broken session: the
    /// link stays up, and the caller sends again once answers free slots.
    pub fn send(self: *Link, comptime Args: type, comptime method: proto.Method, args: Args) !u32 {
        if (self.state != .connected) return error.NotConnected;
        if (self.native) |n| return n.send(Args, method, args);
        return self.client.call(Args, @backingInt(method), args, 0, self.tx) catch |err| {
            if (err != error.TableFull) self.fail(err);
            return err;
        };
    }

    /// Stop using the session. The transport's owner closes it.
    pub fn close(self: *Link) void {
        self.state = .closed;
    }

    fn fail(self: *Link, err: proto.Error) void {
        self.state = .{ .failed = classify(err) };
    }

    /// The wire as the client sees it: a readable end that yields nothing
    /// has hung up, which the library would otherwise wait on forever.
    fn watched(self: *Link) rpc.Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable: rpc.Transport.VTable = .{ .send = relay, .receive = take, .poll = peek };
    fn from(ctx: *anyopaque) *Link {
        return @ptrCast(@alignCast(ctx));
    }
    fn relay(ctx: *anyopaque, bytes: []const u8) rpc.Transport.Error!void {
        return from(ctx).inner.send(bytes);
    }
    fn take(ctx: *anyopaque, into: []u8) rpc.Transport.Error!usize {
        const count = try from(ctx).inner.receive(into);
        return if (count == 0) error.LinkDown else count;
    }
    fn peek(ctx: *anyopaque) usize {
        return from(ctx).inner.poll();
    }
};

/// A `serve --stdio` child of `exe` (ra8_emulator), spoken to over its
/// pipes. The shell itself serves a local image in-process
/// (local_session.zig).
pub const Local = struct {
    child: std.process.Child,
    io: std.Io,
    pipes: Stdio = .{},

    /// Start `exe serve --stdio elf`. Its stderr stays the GUI's.
    pub fn spawn(self: *Local, io: std.Io, exe: []const u8, elf: []const u8) !void {
        return self.spawnArgs(io, exe, elf, &.{});
    }

    /// Start `exe serve --stdio elf <args>`; args are the session's own flags
    /// (for example `--cpu1 <image>` to arm the second core).
    pub fn spawnArgs(self: *Local, io: std.Io, exe: []const u8, elf: []const u8, args: []const []const u8) !void {
        var argv: [8][]const u8 = undefined;
        std.debug.assert(4 + args.len <= argv.len);
        argv[0] = exe;
        argv[1] = "serve";
        for (args, 0..) |a, i| argv[2 + i] = a;
        argv[2 + args.len] = "--stdio";
        argv[3 + args.len] = elf;
        self.* = .{ .io = io, .child = try std.process.spawn(io, .{ .argv = argv[0 .. 4 + args.len], .stdin = .pipe, .stdout = .pipe, .stderr = .inherit }) };
        self.pipes = .{ .input = self.child.stdout.?.handle, .output = self.child.stdin.?.handle };
    }

    pub fn transport(self: *Local) rpc.Transport {
        return self.pipes.transport();
    }

    /// Close the child's stdin, which tells `serve` to exit.
    pub fn end(self: *Local) void {
        if (self.child.stdin) |file| file.close(self.io);
        self.child.stdin = null;
    }

    /// Wait for the child once it has been told to end.
    pub fn reap(self: *Local) !std.process.Child.Term {
        return self.child.wait(self.io);
    }
};
