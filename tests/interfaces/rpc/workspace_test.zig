//! Workspace requests cross the real codec, client and server route table.
const std = @import("std");
const ra8 = @import("ra8");
const rpc = ra8.rpc.session.server.rpc_lib;
const proto = ra8.rpc.session.rpc;
const wire = ra8.rpc.workspace_wire;
const served = ra8.rpc.session.server;
const io = std.testing.io;

const Fixture = struct {
    session: ra8.session.api.Session = .{ .live = undefined }, // never run by filesystem routes
    context: served.Context = undefined,
    loop: rpc.Loopback = undefined,
    client: proto.Client = undefined,
    server: served.Host = undefined,
    tx: []u8 = undefined,
    client_rx: []u8 = undefined,
    server_rx: []u8 = undefined,

    fn init(self: *Fixture, gpa: std.mem.Allocator, root: ?*ra8.host.workspace.Workspace) !void {
        const size = proto.Client.Env.max_frame;
        self.tx = try gpa.alloc(u8, size);
        self.client_rx = try gpa.alloc(u8, 2 * size);
        self.server_rx = try gpa.alloc(u8, 2 * size);
        self.loop = rpc.Loopback.init(try gpa.alloc(u8, 2 * size), try gpa.alloc(u8, 2 * size));
        self.context = .{ .session = &self.session, .scratch = try gpa.alloc(u8, proto.max_payload), .workspace = root };
        try self.connect();
    }

    fn connect(self: *Fixture) !void {
        self.client = proto.Client.init(self.loop.a(), self.client_rx, proto.capabilities);
        self.server = served.Host.init(self.loop.b(), self.server_rx, &self.context);
        try self.client.greet(self.tx);
        try std.testing.expectEqual(rpc.Step.greeted, try self.server.poll(self.tx));
        const ready = (try self.client.poll(self.tx)).?.ready;
        try std.testing.expectEqual(self.context.workspace != null, ready & wire.capability != 0);
    }

    fn call(self: *Fixture, comptime T: type, method: wire.Method, args: T) !proto.Client.Env.Result {
        _ = try self.client.call(T, @backingInt(method), args, 0, self.tx);
        try std.testing.expectEqual(rpc.Step.answered, try self.server.poll(self.tx));
        return (try self.client.poll(self.tx)).?.response.result;
    }
};

fn answer(comptime T: type, result: proto.Client.Env.Result) !T {
    return switch (result) {
        .ok => |bytes| try proto.decode(T, bytes),
        .err => error.Refused,
    };
}

fn refused(result: proto.Client.Env.Result, expected: u16) !void {
    switch (result) {
        .ok => return error.UnexpectedSuccess,
        .err => |code| try std.testing.expectEqual(expected, @as(u16, @backingInt(code))),
    }
}

test "workspace RPC creates reads lists and saves with conflict protection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: ra8.host.workspace.Workspace = .{ .dir = tmp.dir, .io = io };
    var fixture: Fixture = .{};
    try fixture.init(arena.allocator(), &root);
    defer fixture.server.deinit();
    var token: [wire.version_bytes]u8 = undefined;
    const missing = try wire.encodeVersion(.{}, &token);
    const original = try answer(wire.Version, try fixture.call(wire.Write, .write, .{ .path = "source.zig", .expected = missing, .bytes = "original" }));
    const read = try answer(wire.Contents, try fixture.call(wire.Read, .read, .{ .path = "source.zig", .offset = 0, .length = 128 }));
    try std.testing.expectEqualStrings("original", read.bytes);
    try std.testing.expect(original.same(try wire.decodeVersion(read.version)));
    const expected = try wire.encodeVersion(original, &token);
    _ = try answer(wire.Version, try fixture.call(wire.Write, .write, .{ .path = "source.zig", .expected = expected, .bytes = "edited" }));
    try refused(try fixture.call(wire.Write, .write, .{ .path = "source.zig", .expected = expected, .bytes = "stale" }), wire.codes.conflict);
    const page = try answer(wire.Page, try fixture.call(wire.List, .list, .{ .path = "", .offset = 0, .limit = 1 }));
    try std.testing.expectEqual(@as(u16, 1), page.count);
    try std.testing.expect(std.mem.indexOf(u8, page.entries, "source.zig") != null);
    var bytes: [32]u8 = undefined;
    try std.testing.expectEqualStrings("edited", (try root.read("source.zig", 0, &bytes)).bytes);
    try refused(try fixture.call(wire.Path, .stat, .{ .path = "../outside" }), wire.codes.invalid_path);
    try refused(try fixture.call(wire.Write, .write, .{ .path = "source.zig", .expected = "bad", .bytes = "bad" }), @backingInt(rpc.Code.bad_args));
}

test "workspace capability is opt-in and reconnect clears the old client's watches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: ra8.host.workspace.Workspace = .{ .dir = tmp.dir, .io = io };
    var fixture: Fixture = .{};
    try fixture.init(arena.allocator(), null);
    try refused(try fixture.call(wire.Path, .stat, .{ .path = "" }), wire.codes.unavailable);
    fixture.server.deinit();
    fixture.context.workspace = &root;
    try fixture.connect();
    const old = try answer(wire.Watch, try fixture.call(wire.Path, .watch, .{ .path = "future" }));
    fixture.server.deinit();
    for (fixture.context.workspace_watches.slots) |slot| try std.testing.expectEqual(@as(u32, 0), slot.id);
    try fixture.connect();
    defer fixture.server.deinit();
    const next = try answer(wire.Watch, try fixture.call(wire.Path, .watch, .{ .path = "future" }));
    try std.testing.expect(next.id > old.id);
    try refused(try fixture.call(wire.Watch, .unwatch, old), wire.codes.invalid_watch);
    _ = try answer(proto.Ack, try fixture.call(wire.Watch, .unwatch, next));
}
