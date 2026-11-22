//! Host tests for the dedicated `ra8_emulator serve` worker thread (RA8EMU-1238):
//! continuous forward `.play` advances virtual time decoupled from `Host.poll`,
//! live RPC inspection brackets safely at slice boundaries, and breakpoint
//! stops emit both `.transport` and `.stop` events.
const std = @import("std");
const ra8 = @import("ra8");

const proto = ra8.rpc.session.rpc;
const served = ra8.rpc.session.server;
const setup = ra8.rpc.served_setup;
const rpc = served.rpc_lib;

const Env = proto.Client.Env;
const caps = proto.capabilities | proto.transport_cap;
const spin_image = "tests/fixtures/profile/call_tree.elf";
const loop_image = "tests/fixtures/dfu/dfu_bootloader.elf";

const Wire = struct {
    gpa: std.mem.Allocator,
    pipes: [2][]u8,
    rx: [2][]u8,
    tx: []u8,
    loop: rpc.Loopback = undefined,
    client: proto.Client = undefined,
    host: served.Host = undefined,
    last_stop: ?proto.Stopped = null,
    stop_count: usize = 0,
    live_transport_count: usize = 0,
    finished_transport: ?proto.TransportEvent = null,
    last_reached_ns: u64 = 0,

    fn init(gpa: std.mem.Allocator) !*Wire {
        const self = try gpa.create(Wire);
        self.* = .{
            .gpa = gpa,
            .pipes = undefined,
            .rx = undefined,
            .tx = try gpa.alloc(u8, Env.max_frame),
        };
        for (&self.pipes) |*pipe| pipe.* = try gpa.alloc(u8, 4 * Env.max_frame);
        for (&self.rx) |*rx| rx.* = try gpa.alloc(u8, 4 * Env.max_frame);
        self.loop = rpc.Loopback.init(self.pipes[0], self.pipes[1]);
        return self;
    }

    fn deinit(self: *Wire) void {
        for (self.pipes ++ self.rx) |buf| self.gpa.free(buf);
        self.gpa.free(self.tx);
        self.gpa.destroy(self);
    }

    fn open(self: *Wire, context: *served.Context) !void {
        self.client = proto.Client.init(self.loop.a(), self.rx[0], caps);
        self.host = served.Host.init(self.loop.b(), self.rx[1], context);
        try self.client.greet(self.tx);
        try std.testing.expectEqual(rpc.Step.greeted, try self.host.poll(self.tx));
        const ready = (try self.client.poll(self.tx)).?;
        try std.testing.expectEqual(caps, ready.ready);
    }

    fn call(
        self: *Wire,
        comptime Args: type,
        comptime Reply: type,
        method: proto.Method,
        args: Args,
    ) !Reply {
        _ = try self.client.call(Args, @backingInt(method), args, 0, self.tx);
        return self.finish(Reply);
    }

    fn finish(self: *Wire, comptime Reply: type) !Reply {
        _ = try self.host.poll(self.tx);
        var reply_value: ?Reply = null;
        var refused = false;
        while (try self.client.poll(self.tx)) |incoming| switch (incoming) {
            .response => |response| switch (response.result) {
                .ok => |bytes| reply_value = try proto.decode(Reply, bytes),
                .err => refused = true,
            },
            .event => |event| try self.record(event.topic, event.payload),
            .ready => return error.Unexpected,
        };
        if (refused) return error.RpcRefused;
        return reply_value orelse error.NoResponse;
    }

    fn pumpEvents(self: *Wire) !void {
        _ = try self.host.poll(self.tx);
        while (try self.client.poll(self.tx)) |incoming| switch (incoming) {
            .event => |event| try self.record(event.topic, event.payload),
            .response, .ready => return error.Unexpected,
        };
    }

    fn record(self: *Wire, topic: u16, payload: []const u8) !void {
        const known: proto.Topic = @fromBackingInt(@intCast(topic));
        switch (known) {
            .stop => {
                self.last_stop = try proto.decode(proto.Stopped, payload);
                self.stop_count += 1;
            },
            .transport => {
                const evt = try proto.decode(proto.TransportEvent, payload);
                if (evt.reached_ns > self.last_reached_ns) self.last_reached_ns = evt.reached_ns;
                if (evt.finished != 0) {
                    self.finished_transport = evt;
                } else {
                    self.live_transport_count += 1;
                }
            },
            else => {},
        }
    }
};

fn findLoopPc(s: *setup.Served) !u32 {
    const sess = s.owner.session();
    var seen: [300]u32 = undefined;
    for (&seen) |*slot| {
        _ = try sess.run(.cpu0, .step);
        slot.* = (try sess.register(.cpu0, .pc)) & ~@as(u32, 1);
    }
    for (seen[0 .. seen.len - 1], 0..) |pc, idx| {
        for (seen[idx + 1 ..]) |later| if (later == pc) return pc;
    }
    return error.NoLoopFound;
}

test "worker pumps continuous forward play without Host.poll and brackets pauses cleanly" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var s: setup.Served = undefined;
    try s.open(gpa, io, spin_image, null, .{ .root = root });
    defer s.deinit();
    try s.startWorker();

    const wire = try Wire.init(gpa);
    defer wire.deinit();
    try wire.open(&s.context);

    _ = try wire.call(proto.Subscription, proto.Ack, .subscribe, .{ .core = .cpu0, .topic = .stop });
    _ = try wire.call(proto.Subscription, proto.Ack, .subscribe, .{ .core = .cpu0, .topic = .transport });
    const ack = try wire.call(proto.PlayArgs, proto.Ack, .play, .{ .dir = .fwd, .speed_milli = 0 });
    try std.testing.expectEqual(@as(u8, 1), ack.accepted);

    const worker = s.worker.?;
    var tries: usize = 0;
    while (worker.slicesPumped() < 2 and tries < 200) : (tries += 1) {
        try io.sleep(.fromMilliseconds(5), .awake);
    }
    try std.testing.expect(worker.slicesPumped() >= 2);
    try std.testing.expect(worker.isActive() or wire.finished_transport != null);

    // Wait >35ms so the next Host.poll also crosses the live progress throttle.
    try io.sleep(.fromMilliseconds(40), .awake);
    const now_ns = try wire.call(proto.Now, proto.U64, .now, .{ .core = .cpu0 });
    try std.testing.expect(now_ns.value > 0);
    try std.testing.expect(wire.last_reached_ns > 0);

    _ = try wire.call(proto.CoreOnly, proto.Ack, .pause, .{ .core = .cpu0 });
    try std.testing.expect(!worker.isActive());
    const pc = try wire.call(proto.ReadRegister, proto.U32, .read_register, .{
        .core = .cpu0,
        .register = .pc,
    });
    try std.testing.expect(pc.value != 0);
}

test "worker halts on breakpoint during play and emits stop and transport events" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var s: setup.Served = undefined;
    try s.open(gpa, io, loop_image, null, .{ .root = root });
    defer s.deinit();
    const loop_pc = try findLoopPc(&s);
    try s.startWorker();

    const wire = try Wire.init(gpa);
    defer wire.deinit();
    try wire.open(&s.context);

    _ = try wire.call(proto.Subscription, proto.Ack, .subscribe, .{ .core = .cpu0, .topic = .stop });
    _ = try wire.call(proto.Subscription, proto.Ack, .subscribe, .{ .core = .cpu0, .topic = .transport });
    _ = try wire.call(proto.Point, proto.U32, .set_breakpoint, .{ .core = .cpu0, .address = loop_pc });

    const ack = try wire.call(proto.PlayArgs, proto.Ack, .play, .{ .dir = .fwd, .speed_milli = 0 });
    try std.testing.expectEqual(@as(u8, 1), ack.accepted);

    var tries: usize = 0;
    while ((wire.finished_transport == null or wire.last_stop == null) and tries < 400) : (tries += 1) {
        try wire.pumpEvents();
        if (wire.finished_transport != null and wire.last_stop != null) break;
        try io.sleep(.fromMilliseconds(2), .awake);
    }

    const fin = wire.finished_transport orelse return error.MissingFinishedEvent;
    try std.testing.expectEqual(@as(u8, 1), fin.finished);
    try std.testing.expectEqual(proto.StopReason.breakpoint, fin.reason);
    try std.testing.expectEqual(loop_pc, fin.address);

    const stop = wire.last_stop orelse return error.MissingStopEvent;
    try std.testing.expectEqual(proto.StopReason.breakpoint, stop.reason);
    try std.testing.expectEqual(loop_pc, stop.address);
    try std.testing.expect(!s.worker.?.isActive());
}
