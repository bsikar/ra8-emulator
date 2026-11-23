const std = @import("std");

const rpc = @import("ra8").rpc;
const handlers = rpc.session.handlers;
const lifecycle = rpc.session.lifecycle;
const proto = rpc.session.rpc;
const Slot = rpc.session_slot.Slot;
const image = @embedFile("../../fixtures/gpio/blink.elf");

fn commit(slot: *Slot) void {
    const hooks = slot.context.lifecycle.?;
    hooks.commitFn(hooks.context);
    slot.context.session_change_pending = false;
}

test "idle service loads atomically, closes, and accepts another image" {
    var slot: Slot = undefined;
    try slot.init(std.testing.allocator, std.testing.io, .{});
    defer slot.deinit();
    try std.testing.expectEqual(@as(u8, 0), lifecycle.status(&slot.context, .{}).ok.loaded);
    const step = lifecycle.guard(.step, handlers.step);
    const refused = step(&slot.context, .{ .core = .cpu0 });
    try std.testing.expectEqual(proto.app_codes.no_session, @as(u16, @intCast(@backingInt(refused.err))));
    try std.testing.expect(handlers.load(&slot.context, .{ .core = .cpu0, .image = "invalid" }) == .err);
    try std.testing.expect(slot.context.session == null);
    try std.testing.expect(handlers.subscribe(&slot.context, .{ .core = .cpu0, .topic = .session }) == .ok);
    const lcd: proto.Subscription = .{ .core = .cpu0, .topic = .lcd_dirty, .rate = 60 };
    try std.testing.expect(handlers.subscribe(&slot.context, lcd) == .ok);
    try std.testing.expect(handlers.load(&slot.context, .{ .core = .cpu0, .image = image }) == .ok);
    try std.testing.expect(slot.context.session == null);
    commit(&slot);
    try std.testing.expectEqual(@as(u8, 1), lifecycle.status(&slot.context, .{}).ok.loaded);
    try std.testing.expect(slot.context.session_feed != null);
    try std.testing.expectEqual(@as(u16, 60), slot.context.lcd_rate[0]);
    const prior = slot.context.session;
    try std.testing.expect(handlers.load(&slot.context, .{ .core = .cpu0, .image = "invalid" }) == .err);
    try std.testing.expectEqual(prior, slot.context.session);
    try std.testing.expect(step(&slot.context, .{ .core = .cpu0 }) == .ok);
    try std.testing.expect(lifecycle.close(&slot.context, .{}) == .ok);
    commit(&slot);
    try std.testing.expect(slot.context.session == null);
    try std.testing.expectEqual(@as(u16, 60), slot.context.lcd_rate[0]);
    try std.testing.expect(handlers.load(&slot.context, .{ .core = .cpu0, .image = image }) == .ok);
    commit(&slot);
    try std.testing.expect(slot.context.session != null);
}

test "a discarded load preserves the live session and frees its candidate" {
    var slot: Slot = undefined;
    try slot.init(std.testing.allocator, std.testing.io, .{});
    defer slot.deinit();
    try std.testing.expect(handlers.load(&slot.context, .{ .core = .cpu0, .image = image }) == .ok);
    commit(&slot);
    const prior = slot.context.session;
    try std.testing.expect(handlers.load(&slot.context, .{ .core = .cpu0, .image = image }) == .ok);
    const hooks = slot.context.lifecycle.?;
    hooks.discardFn(hooks.context);
    try std.testing.expect(slot.pending == null);
    try std.testing.expect(!slot.context.session_change_pending);
    try std.testing.expectEqual(prior, slot.context.session);
}
