//! Covers src/core/cpu/lockstep/writes.zig.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.core.cpu.bus;
const writes = ra8.core.cpu.lockstep.writes;

/// 64 bytes of memory at address 0.
const Flat = struct {
    bytes: [64]u8 = [_]u8{0} ** 64,

    fn view(self: *Flat) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Flat = @ptrCast(@alignCast(ctx));
        if (address + into.len > self.bytes.len) return bus.Error.Unmapped;
        @memcpy(into, self.bytes[address..][0..into.len]);
    }

    fn write(ctx: *anyopaque, address: u32, bytes: []const u8) bus.Error!void {
        const self: *Flat = @ptrCast(@alignCast(ctx));
        if (address + bytes.len > self.bytes.len) return bus.Error.Unmapped;
        @memcpy(self.bytes[address..][0..bytes.len], bytes);
    }
};

test "a store reaches memory and is kept with its address and bytes" {
    var memory: Flat = .{};
    var made: writes.Recorder = .{ .inner = memory.view() };
    try made.view().write(8, &.{ 0xDE, 0xAD });
    try std.testing.expectEqual(@as(u8, 0xAD), memory.bytes[9]);
    try std.testing.expectEqual(@as(usize, 1), made.items().len);
    try std.testing.expectEqual(@as(u32, 8), made.items()[0].address);
    try std.testing.expectEqualSlices(u8, &.{ 0xDE, 0xAD }, made.items()[0].slice());
}

test "a store wider than a chunk is kept in chunks" {
    var memory: Flat = .{};
    var made: writes.Recorder = .{ .inner = memory.view() };
    try made.view().write(0, &([_]u8{0x11} ** 12));
    try std.testing.expectEqual(@as(usize, 2), made.items().len);
    try std.testing.expectEqual(@as(u32, writes.widest), made.items()[1].address);
    try std.testing.expectEqual(@as(u8, 12 - writes.widest), made.items()[1].len);
}

test "a store that faults is not kept, and reads pass through" {
    var memory: Flat = .{};
    memory.bytes[3] = 0x5A;
    var made: writes.Recorder = .{ .inner = memory.view() };
    try std.testing.expectError(bus.Error.Unmapped, made.view().write(100, &.{1}));
    try std.testing.expectEqual(@as(usize, 0), made.items().len);
    var byte: [1]u8 = undefined;
    try made.view().read(3, &byte);
    try std.testing.expectEqual(@as(u8, 0x5A), byte[0]);
}

test "past its capacity the recorder says it dropped stores" {
    var memory: Flat = .{};
    var made: writes.Recorder = .{ .inner = memory.view() };
    var i: usize = 0;
    while (i <= writes.capacity) : (i += 1) try made.view().write(0, &.{0});
    try std.testing.expect(made.dropped);
    try std.testing.expectEqual(@as(usize, writes.capacity), made.items().len);
}
