//! Catalog identity by callbacks: misaligned known parts and foreign contexts.
const std = @import("std");
const ra8 = @import("ra8");
const c = ra8.components;
const Rig = @import("attachments_test.zig").Rig;
const Plugs = ra8.session.board.plug.Plugs;
const Endpoint = c.endpoint.Endpoint;
const Allocating = std.Io.Writer.Allocating;
const imu_at: Endpoint = .{ .i2c = .{ .line = .riic, .address = 0x6a } };
const led_at: Endpoint = .{ .gpio = .{ .port = 1, .pin = 6 } };
const button_at: Endpoint = .{ .gpio = .{ .port = 1, .pin = 4 } };

fn stateOf(comptime T: type, instance: c.catalog.Instance) *T {
    return @ptrCast(@alignCast(instance.state));
}

fn imuBytes(rig: *Rig) ![2]u8 {
    var bytes: [2]u8 = undefined;
    const device = rig.board.wire.controller.devices.find(0x6a) orelse return error.Missing;
    try std.testing.expectEqual(@as(usize, 2), device.read(&bytes));
    return bytes;
}

fn owned(rig: *Rig, name: []const u8) !c.catalog.Instance {
    for (rig.plugs.snapshot_owned[0..rig.plugs.snapshot_owned_count]) |instance| {
        if (std.mem.eql(u8, instance.model.name, name)) return instance;
    }
    return error.Missing;
}

test "attachment strict runtime IMU then misaligned LED and button restore through the graph" {
    const live = try Rig.create();
    defer live.destroy();
    try live.plugs.set(imu_at, "lsm6dso");
    try live.plugs.set(led_at, "led");
    try live.plugs.set(button_at, "button");
    try std.testing.expect(@intFromPtr(live.plugs.instances[1].state) % 8 != 0);
    const imu = stateOf(c.lsm6dso.Imu, live.plugs.instances[0]);
    imu.write(c.lsm6dso.reg.ctrl1_xl);
    imu.write(0x40);
    imu.stop();
    imu.write(c.lsm6dso.reg.outz_l_a);
    stateOf(c.led.Led, live.plugs.instances[1]).* = .{ .lit = true, .edges = 5 };
    stateOf(c.button.Button, live.plugs.instances[2]).pressed = true;
    var saved = Allocating.init(std.testing.allocator);
    defer saved.deinit();
    try live.files.writeTo(&saved.writer);
    const expected = try imuBytes(live);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0x40 }, &expected);
    stateOf(c.led.Led, live.plugs.instances[1]).* = .{};
    stateOf(c.button.Button, live.plugs.instances[2]).pressed = false;
    const fresh = try Rig.create();
    defer fresh.destroy();
    for ([_]*Rig{ live, fresh }) |target| {
        try target.files.readFrom(saved.written());
        try std.testing.expectEqual(@as(usize, 3), target.plugs.instance_count);
        try std.testing.expectEqual(c.led.Led{ .lit = true, .edges = 5 }, stateOf(c.led.Led, target.plugs.instances[1]).*);
        try std.testing.expect(stateOf(c.button.Button, target.plugs.instances[2]).pressed);
        try std.testing.expectEqualSlices(u8, &expected, &try imuBytes(target));
        var again = Allocating.init(std.testing.allocator);
        defer again.deinit();
        try target.files.writeTo(&again.writer);
        try target.files.readFrom(again.written());
        try std.testing.expectEqual(c.led.Led{ .lit = true, .edges = 5 }, stateOf(c.led.Led, target.plugs.instances[1]).*);
    }
}

test "attachment strict startup IMU then LED and button restore through the graph" {
    const live = try Rig.create();
    defer live.destroy();
    const asks = [_]c.request.Request{
        .{ .name = "lsm6dso", .at = imu_at },
        .{ .name = "led", .at = led_at },
        .{ .name = "button", .at = button_at },
    };
    live.board.asks.keep(live.arena.allocator(), &asks);
    try ra8.board.plug.all(&live.board);
    live.plugs = Plugs.init(&live.board, live.arena.allocator());
    var first = Allocating.init(std.testing.allocator);
    defer first.deinit();
    try live.files.writeTo(&first.writer);
    try live.files.readFrom(first.written());
    stateOf(c.led.Led, try owned(live, "led")).* = .{ .lit = true, .edges = 9 };
    stateOf(c.button.Button, try owned(live, "button")).pressed = true;
    var saved = Allocating.init(std.testing.allocator);
    defer saved.deinit();
    try live.files.writeTo(&saved.writer);
    stateOf(c.led.Led, try owned(live, "led")).* = .{};
    try live.files.readFrom(saved.written());
    try std.testing.expectEqual(c.led.Led{ .lit = true, .edges = 9 }, stateOf(c.led.Led, try owned(live, "led")).*);
    try std.testing.expect(stateOf(c.button.Button, try owned(live, "button")).pressed);
    try std.testing.expectEqualSlices(u8, &.{ c.lsm6dso.identity, 0 }, &try whoAmI(live));
}

fn whoAmI(rig: *Rig) ![2]u8 {
    const device = rig.board.wire.controller.devices.find(0x6a) orelse return error.Missing;
    device.write(c.lsm6dso.reg.who_am_i);
    var bytes = try imuBytes(rig);
    bytes[1] = 0;
    return bytes;
}

fn foreignFeed(_: *anyopaque, _: u8) []const u8 {
    return &.{};
}

test "attachment strict unknown under-aligned context refuses save and restore without mutation" {
    const rig = try Rig.create();
    defer rig.destroy();
    var saved = Allocating.init(std.testing.allocator);
    defer saved.deinit();
    try rig.files.writeTo(&saved.writer);
    var storage: [16]u8 align(8) = @splat(0x5a);
    rig.cpu.regs.low[5] = 0x1234;
    for ([_]usize{ 1, 4 }) |offset| {
        const context: *anyopaque = &storage[offset];
        try std.testing.expectEqual(offset, @intFromPtr(context) % 8);
        rig.board.serial.channels[4].device = .{ .context = context, .feedFn = foreignFeed };
        var out = Allocating.init(std.testing.allocator);
        defer out.deinit();
        try std.testing.expectError(error.UnsupportedAttachment, rig.files.writeTo(&out.writer));
        try std.testing.expectEqual(@as(usize, 0), out.written().len);
        try std.testing.expectError(error.UnsupportedAttachment, rig.files.readFrom(saved.written()));
        const held = rig.board.serial.channels[4].device.?;
        try std.testing.expect(held.context == context and held.feedFn == &foreignFeed);
        try std.testing.expectEqual(@as(u32, 0x1234), rig.cpu.regs.low[5]);
        try std.testing.expectEqualSlices(u8, &@as([16]u8, @splat(0x5a)), &storage);
    }
}
