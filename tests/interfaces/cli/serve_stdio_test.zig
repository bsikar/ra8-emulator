//! Spawns `ra8_emulator serve --stdio` and drives it over its pipes
//! (RA8EMU-737): greet, load, run, pause, read registers, close stdin.
const std = @import("std");
const ra8 = @import("ra8");
const test_paths = @import("test_paths");
const proto = ra8.interfaces.rpc.session;
const Stdio = ra8.interfaces.rpc.stdio.Stdio;

const image_path = "tests/fixtures/fpu/fp_basic.elf";
const Env = proto.Client.Env;
const Incoming = proto.Client.Incoming;

/// A client on the child's pipes with buffers off the stack.
const Peer = struct {
    gpa: std.mem.Allocator,
    pipes: Stdio,
    rx: []u8,
    tx: []u8,
    client: proto.Client = undefined,

    fn init(gpa: std.mem.Allocator, child: *std.process.Child) !*Peer {
        const self = try gpa.create(Peer);
        self.* = .{
            .gpa = gpa,
            .pipes = .{ .input = child.stdout.?.handle, .output = child.stdin.?.handle },
            .rx = try gpa.alloc(u8, 2 * Env.max_frame),
            .tx = try gpa.alloc(u8, Env.max_frame),
        };
        self.client = proto.Client.init(self.pipes.transport(), self.rx, proto.capabilities);
        return self;
    }

    fn deinit(self: *Peer) void {
        self.gpa.free(self.rx);
        self.gpa.free(self.tx);
        self.gpa.destroy(self);
    }

    /// The next frame from the server, or an error after ten seconds.
    fn next(self: *Peer) !Incoming {
        const deadline = std.time.milliTimestamp() + 10_000;
        while (std.time.milliTimestamp() < deadline) {
            if (try self.client.poll(self.tx)) |incoming| return incoming;
            std.time.sleep(std.time.ns_per_ms);
        }
        return error.ServerSilent;
    }

    /// Call `method` and decode its `Reply`, skipping any events on the way.
    fn call(self: *Peer, comptime Reply: type, comptime Args: type, method: proto.Method, args: Args) !Reply {
        _ = try self.client.call(Args, @intFromEnum(method), args, 0, self.tx);
        while (true) switch (try self.next()) {
            .response => |response| return switch (response.result) {
                .ok => |bytes| try proto.decode(Reply, bytes),
                .err => error.Refused,
            },
            else => {},
        };
    }
};

test "serve --stdio answers a client on its pipes and exits 0 once stdin closes" {
    const gpa = std.testing.allocator;
    var child = std.process.Child.init(&.{ test_paths.emulator, "serve", "--stdio", image_path }, gpa);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    errdefer _ = child.kill() catch {};
    const peer = try Peer.init(gpa, &child);
    defer peer.deinit();

    try peer.client.greet(peer.tx);
    try std.testing.expectEqual(proto.capabilities, (try peer.next()).ready);
    const image = try std.fs.cwd().readFileAlloc(gpa, image_path, 1 << 20);
    defer gpa.free(image);
    _ = try peer.call(proto.Ack, proto.Load, .load, .{ .core = .cpu0, .image = image });
    _ = try peer.call(proto.Ack, proto.Run, .run, .{ .core = .cpu0, .mode = .cont, .budget = 1000 });
    _ = try peer.call(proto.Ack, proto.CoreOnly, .pause, .{ .core = .cpu0 });
    const pc = try peer.call(proto.U32, proto.ReadRegister, .read_register, .{ .core = .cpu0, .register = .pc });
    const sp = try peer.call(proto.U32, proto.ReadRegister, .read_register, .{ .core = .cpu0, .register = .sp });
    try std.testing.expect(pc.value != 0);
    try std.testing.expect(sp.value != 0);

    child.stdin.?.close();
    child.stdin = null;
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, try child.wait());
}

test "serve without --stdio prints its usage and exits 2" {
    const result = try std.process.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &.{ test_paths.emulator, "serve", image_path },
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 2 }, result.term);
    try std.testing.expectEqualStrings(ra8.core.serve_main.usage, result.stderr);
    try std.testing.expectEqualStrings("", result.stdout);
}
