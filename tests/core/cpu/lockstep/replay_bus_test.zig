//! Covers src/core/cpu/lockstep/replay_bus.zig: a read and a write in the
//! peripheral window go to the log, never to memory or a peripheral.
const std = @import("std");
const ra8 = @import("ra8");
const periph_log = ra8.core.cpu.lockstep.periph_log;
const ReplayBus = ra8.core.cpu.lockstep.replay_bus.ReplayBus;
const registry = ra8.periph.registry;

fn busWith(log: *periph_log.Log) ReplayBus {
    // The engine is never reached: every access below is in the window.
    return .{ .memory = .{ .core = undefined }, .log = log };
}

test "a window read returns Unicorn's value" {
    var log: periph_log.Log = .{};
    log.begin(true);
    log.noteRead(.{ .address = registry.base + 0x10, .width = 2, .value = 0xBEEF });
    var replay = busWith(&log);
    var into: [2]u8 = undefined;
    try replay.view().read(registry.base + 0x10, &into);
    try std.testing.expectEqual(@as(u16, 0xBEEF), std.mem.readInt(u16, &into, .little));
    try std.testing.expect(log.verdict() == null);
}

test "a window write is checked against Unicorn's, in the Non-secure alias too" {
    var log: periph_log.Log = .{};
    log.begin(true);
    log.noteWrite(.{ .address = registry.ns_base + 4, .width = 4, .value = 0x1234_5678 });
    var replay = busWith(&log);
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, 0x1234_5678, .little);
    try replay.view().write(registry.ns_base + 4, &bytes);
    try std.testing.expect(log.verdict() == null);
    try std.testing.expectEqual(@as(u64, 1), log.matched);
}

test "an unarmed log refuses window accesses, a mismatched read completes with zero" {
    var log: periph_log.Log = .{};
    var replay = busWith(&log);
    var into: [4]u8 = undefined;
    try std.testing.expectError(error.Unmapped, replay.view().read(registry.base, &into));
    log.begin(true);
    try replay.view().read(registry.base, &into);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, &into, .little));
    try std.testing.expect(log.verdict().?.oracle == null);
}
