//! Covers src/core/cpu/exclusive_peer.zig.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.core.cpu.bus;
const exclusive_peer = ra8.core.cpu.exclusive_peer;
const Cpu = ra8.core.cpu.cpu.Cpu;

/// Shared SRAM both cores store into.
const Shared = struct {
    const base: u32 = 0x2200_0000;
    bytes: [64]u8 = [_]u8{0} ** 64,

    fn view(self: *Shared) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn span(self: *Shared, address: u32, len: usize) bus.Error![]u8 {
        if (address < base or address - base + len > self.bytes.len) return bus.Error.Unmapped;
        return self.bytes[address - base ..][0..len];
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Shared = @ptrCast(@alignCast(ctx));
        @memcpy(into, try self.span(address, into.len));
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        const self: *Shared = @ptrCast(@alignCast(ctx));
        @memcpy(try self.span(address, from.len), from);
    }
};

fn storedOver(tagged: ?u32, address: u32, len: usize) ?u32 {
    var tag = tagged;
    (exclusive_peer.Peer{ .tag = &tag }).stored(address, len);
    return tag;
}

test "a store into the tagged word clears the tag" {
    try std.testing.expectEqual(@as(?u32, null), storedOver(0x2200_0010, 0x2200_0010, 4));
    try std.testing.expectEqual(@as(?u32, null), storedOver(0x2200_0010, 0x2200_0013, 1));
    try std.testing.expectEqual(@as(?u32, null), storedOver(0x2200_0012, 0x2200_0010, 2));
    // A doubleword store that ends in the tagged word.
    try std.testing.expectEqual(@as(?u32, null), storedOver(0x2200_0014, 0x2200_0010, 8));
}

test "a store beside the tagged word keeps the tag" {
    try std.testing.expectEqual(@as(?u32, 0x2200_0010), storedOver(0x2200_0010, 0x2200_000C, 4));
    try std.testing.expectEqual(@as(?u32, 0x2200_0010), storedOver(0x2200_0010, 0x2200_0014, 4));
    try std.testing.expectEqual(@as(?u32, null), storedOver(null, 0x2200_0010, 4));
}

test "paired cores clear each other's monitor through their buses" {
    var shared: Shared = .{};
    var cpu0: Cpu = .{ .bus = shared.view() };
    var cpu1: Cpu = .{ .bus = shared.view() };
    exclusive_peer.pair(&cpu0, &cpu1);
    cpu0.exclusive = 0x2200_0020;
    cpu1.exclusive = 0x2200_0030;
    // CPU1's store to its own tagged word leaves its tag to STREX.
    try cpu1.bus.writeWord(0x2200_0030, 7);
    try std.testing.expectEqual(@as(?u32, 0x2200_0030), cpu1.exclusive);
    try std.testing.expectEqual(@as(?u32, 0x2200_0020), cpu0.exclusive);
    // CPU1 storing into CPU0's word breaks CPU0's reservation.
    try cpu1.bus.writeWord(0x2200_0020, 1);
    try std.testing.expectEqual(@as(?u32, null), cpu0.exclusive);
    // And CPU0 storing into CPU1's word breaks CPU1's.
    try cpu0.bus.writeWord(0x2200_0030, 2);
    try std.testing.expectEqual(@as(?u32, null), cpu1.exclusive);
}

test "unpaired cores watch nothing" {
    var shared: Shared = .{};
    var cpu0: Cpu = .{ .bus = shared.view() };
    var cpu1: Cpu = .{ .bus = shared.view() };
    exclusive_peer.pair(&cpu0, &cpu1);
    exclusive_peer.unpair(&cpu0, &cpu1);
    cpu0.exclusive = 0x2200_0020;
    try cpu1.bus.writeWord(0x2200_0020, 1);
    try std.testing.expectEqual(@as(?u32, 0x2200_0020), cpu0.exclusive);
}
