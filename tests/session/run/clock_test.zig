//! Plain Clock owns live attachment providers across restore.
const std = @import("std");
const ra8 = @import("ra8");
const Rig = @import("../board/attachments_test.zig").Rig;
const Clock = ra8.session.run.loop.Clock;
const snapshot = ra8.session.zig.snapshot;
const codec = ra8.components.catalog_snapshot;
const C6 = ra8.components.esp_hosted.C6;
const Flow = struct {
    var closed: usize = 0;
    fn close(_: ra8.components.esp_hosted.host_net.Handle) void {
        closed += 1;
    }
};

test "plain Clock failed restore keeps C6 flow then commit closes it once" {
    const rig = try Rig.create();
    defer rig.destroy();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const clean_path = try std.fs.path.join(std.testing.allocator, &.{ root, "clean" });
    defer std.testing.allocator.free(clean_path);
    const bad_path = try std.fs.path.join(std.testing.allocator, &.{ root, "bad" });
    defer std.testing.allocator.free(bad_path);
    var clock: Clock = .{ .io = std.testing.io, .memory = .{ .store = &rig.store }, .board = &rig.board, .timebase = &rig.edge.timebase, .state = .{ .save = clean_path } };
    defer clock.deinitSnapshot();
    const owner = clock.snapshotBinding();
    const at: ra8.components.endpoint.Endpoint = .{ .uart = .{ .channel = 4 } };
    try owner.plugs.set(at, "c6");
    const original = codec.cast(C6, owner.plugs.instances[0].state);
    _ = original.wire.exchange(0);
    const hook = snapshot.hook(&clock).?;
    try hook.saveFn.?(hook.context, &rig.cpu, 0);
    const clean = try tmp.dir.readFileAlloc(std.testing.io, "clean", std.testing.allocator, .limited(1 << 27));
    defer std.testing.allocator.free(clean);
    var net = ra8.components.esp_hosted.host_net.Net.of(ra8.host.sock);
    net.close = Flow.close;
    original.wire.bridge.net = net;
    original.wire.bridge.tcp_flows[0].state = .established;
    original.wire.bridge.tcp_flows[0].sock = .{ .net = net, .socket = @fromBackingInt(1) };
    try std.testing.expect(original.wire.bridge.active());
    Flow.closed = 0;
    const section = (try ra8.snapshot.file.Reader.find(clean, .attachments)).?;
    const offset = @intFromPtr(section.payload.ptr) - @intFromPtr(clean.ptr);
    var bad = try std.testing.allocator.dupe(u8, clean);
    defer std.testing.allocator.free(bad);
    bad[offset] = 0xff;
    var out = try tmp.dir.createFile(std.testing.io, "bad", .{});
    defer out.close(std.testing.io);
    try out.writeStreamingAll(std.testing.io, bad);
    clock.state.load = bad_path;
    const load = snapshot.hook(&clock).?;
    try std.testing.expectError(error.BadValue, load.loadFn.?(load.context, &rig.cpu));
    try std.testing.expectEqual(@as(usize, 0), Flow.closed);
    try std.testing.expect(original.wire.bridge.active());
    try std.testing.expect(owner.plugs.instances[0].state == @as(*anyopaque, original));
    clock.state.load = clean_path;
    _ = try load.loadFn.?(load.context, &rig.cpu);
    const restored = codec.cast(C6, owner.plugs.instances[0].state);
    try std.testing.expectEqual(@as(usize, 1), Flow.closed);
    try std.testing.expect(!restored.wire.bridge.active());
    try std.testing.expect(restored.wire.bridge.net.?.close == Flow.close);
    try std.testing.expect(rig.board.pins.observer.?.context == @as(*anyopaque, restored));
}
