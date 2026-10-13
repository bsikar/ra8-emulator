//! Callback capability refusals and C6 ownership transfer oracles.
const std = @import("std");
const ra8 = @import("ra8");
const codec = ra8.components.catalog_snapshot;
const Rig = @import("attachments_test.zig").Rig;
const Endpoint = ra8.components.endpoint.Endpoint;
const modem_at: Endpoint = .{ .uart = .{ .channel = 3 } };

fn foreignFeed(_: *anyopaque, _: u8) []const u8 {
    return &.{};
}

test "attachment strict unknown callbacks and custom factory refuse before any output" {
    const rig = try Rig.create();
    defer rig.destroy();
    var context: u8 = 0;
    rig.board.serial.channels[4].device = .{ .context = &context, .feedFn = foreignFeed };
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    try std.testing.expectError(error.UnsupportedAttachment, rig.files.writeTo(&writer.writer));
    try std.testing.expectEqual(@as(usize, 0), writer.written().len);
    rig.board.serial.channels[4].device = null;
    try rig.plugs.set(modem_at, "modem");
    var factory = rig.plugs.instances[0].model.*;
    rig.plugs.instances[0].model = &factory;
    try std.testing.expectError(error.UnsupportedAttachment, rig.files.writeTo(&writer.writer));
    try std.testing.expectEqual(@as(usize, 0), writer.written().len);
}

fn lookup(_: ?*anyopaque, _: ?std.Io, _: []const u8, _: *[ra8.components.esp_hosted.dns.max_answers][4]u8) !u8 {
    return 0;
}
const Lifecycle = struct {
    var closed: usize = 0;
    fn close(_: ra8.components.esp_hosted.host_net.Handle) void {
        closed += 1;
    }
};

test "attachment strict dynamic C6 host flows close at commit and providers move once" {
    const rig = try Rig.create();
    defer rig.destroy();
    const at: Endpoint = .{ .uart = .{ .channel = 4 } };
    try rig.plugs.set(at, "c6");
    const c6 = codec.cast(ra8.components.esp_hosted.C6, rig.plugs.instances[0].state);
    _ = c6.wire.exchange(0);
    var saved = try rig.save();
    defer saved.deinit();
    var context: u8 = 0;
    c6.wire.bridge.resolver = .{ .context = &context, .io = std.testing.io, .lookupFn = lookup };
    var net = ra8.components.esp_hosted.host_net.Net.of(ra8.host.sock);
    net.close = Lifecycle.close;
    c6.wire.bridge.net = net;
    c6.wire.bridge.tape.misses.store(9, .release);
    c6.wire.bridge.tcp_flows[0].state = .established;
    c6.wire.bridge.tcp_flows[0].sock = .{ .net = net, .socket = @fromBackingInt(1) };
    Lifecycle.closed = 0;
    const corrupt = try std.testing.allocator.dupe(u8, saved.written());
    defer std.testing.allocator.free(corrupt);
    corrupt[corrupt.len - 1] = 0xff;
    try std.testing.expectError(error.BadValue, rig.restore(corrupt));
    try std.testing.expectEqual(@as(usize, 0), Lifecycle.closed);
    try std.testing.expect(c6.wire.bridge.active());
    try rig.restore(saved.written());
    const restored = codec.cast(ra8.components.esp_hosted.C6, rig.plugs.instances[0].state);
    try std.testing.expectEqual(@as(usize, 1), Lifecycle.closed);
    try std.testing.expect(!restored.wire.bridge.active());
    try std.testing.expect(restored.wire.bridge.resolver.context == @as(?*anyopaque, @ptrCast(&context)));
    try std.testing.expect(restored.wire.bridge.resolver.lookupFn == lookup);
    try std.testing.expect(restored.wire.bridge.net.?.close == Lifecycle.close);
    try std.testing.expectEqual(@as(u32, 9), restored.wire.bridge.tape.missed());
    try std.testing.expect(restored.pins == &rig.board.pins);
    try std.testing.expect(rig.board.pins.observer.?.context == @as(*anyopaque, restored));
}

test "attachment strict late fitted model mismatch rejects without replacing devices" {
    const rig = try Rig.create();
    defer rig.destroy();
    const at: Endpoint = .{ .i2c = .{ .line = .riic, .address = 0x36 } };
    try rig.plugs.set(at, "max17048");
    const pointer = rig.gauge().context;
    rig.plugs.fitted[0].name = "lsm6dso";
    var bad = try rig.save();
    defer bad.deinit();
    try std.testing.expectError(error.BadValue, rig.restore(bad.written()));
    try std.testing.expect(pointer == rig.gauge().context);
    try std.testing.expectEqual(@as(usize, 1), rig.plugs.instance_count);
}
