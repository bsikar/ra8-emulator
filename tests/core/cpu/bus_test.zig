//! Covers src/core/cpu/bus.zig.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.core.cpu.bus;

/// A Bus over one slice of bytes at a base address; anything outside it is
/// unmapped.
const Flat = struct {
    base: u32,
    bytes: []u8,

    fn view(self: *Flat) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn span(self: *Flat, address: u32, len: usize) bus.Error![]u8 {
        if (address < self.base) return bus.Error.Unmapped;
        const at = address - self.base;
        if (at + len > self.bytes.len) return bus.Error.Unmapped;
        return self.bytes[at..][0..len];
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Flat = @ptrCast(@alignCast(ctx));
        @memcpy(into, try self.span(address, into.len));
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        const self: *Flat = @ptrCast(@alignCast(ctx));
        @memcpy(try self.span(address, from.len), from);
    }
};

test "halfwords and words read little-endian" {
    var bytes = [_]u8{ 0x00, 0xBF, 0xAF, 0xF3, 0x00, 0x80 };
    var flat: Flat = .{ .base = 0x0800_0000, .bytes = &bytes };
    const b = flat.view();
    try std.testing.expectEqual(@as(u16, 0xBF00), try b.readHalf(0x0800_0000));
    try std.testing.expectEqual(@as(u32, 0xF3AF_BF00), try b.readWord(0x0800_0000));
}

test "a write lands and an access outside the map fails" {
    var bytes = [_]u8{0} ** 4;
    var flat: Flat = .{ .base = 0x2000_0000, .bytes = &bytes };
    const b = flat.view();
    try b.write(0x2000_0002, &.{ 0x34, 0x12 });
    try std.testing.expectEqual(@as(u16, 0x1234), try b.readHalf(0x2000_0002));
    try std.testing.expectError(bus.Error.Unmapped, b.readWord(0x2000_0002));
}
