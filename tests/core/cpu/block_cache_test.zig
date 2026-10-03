//! Covers src/core/cpu/block_cache.zig.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.core.cpu.bus;
const decode = ra8.core.cpu.decode;
const BlockCache = decode.block_cache.BlockCache;

const Ram = struct {
    bytes: [64]u8 = [_]u8{0} ** 64,

    fn view(self: *Ram) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn put(self: *Ram, at: u32, half: u16) void {
        std.mem.writeInt(u16, self.bytes[at..][0..2], half, .little);
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        if (address + into.len > self.bytes.len) return bus.Error.Unmapped;
        @memcpy(into, self.bytes[address..][0..into.len]);
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        _ = .{ ctx, address, from };
        return bus.Error.Unmapped;
    }
};

const m85 = decode.profile.Profile.m85;

fn freshCache() !*BlockCache {
    const cache = try std.testing.allocator.create(BlockCache);
    cache.init();
    return cache;
}

fn straightRun(ram: *Ram) void {
    ram.put(0, 0x2001); // movs r0,#1
    ram.put(2, 0x2102); // movs r1,#2
    ram.put(4, 0xE7FA); // b 0
}

test "a walk through a block forms it once and reuses it" {
    var ram: Ram = .{};
    straightRun(&ram);
    const cache = try freshCache();
    defer std.testing.allocator.destroy(cache);
    for (0..2) |_| {
        for ([_]u32{ 0, 2, 4 }) |at| {
            const kept = cache.next(ram.view(), m85, at).?;
            try std.testing.expectEqual(at, kept.instr.address);
        }
    }
    try std.testing.expectEqual(@as(u64, 1), cache.formed);
    try std.testing.expectEqual(@as(u64, 1), cache.reused);
    try std.testing.expectEqual(@as(u64, 0), cache.stale);
}

test "rewritten code is never handed out stale" {
    var ram: Ram = .{};
    straightRun(&ram);
    const cache = try freshCache();
    defer std.testing.allocator.destroy(cache);
    _ = cache.next(ram.view(), m85, 0).?;
    ram.put(2, 0x2207); // movs r2,#7
    try std.testing.expect(cache.next(ram.view(), m85, 2) == null);
    try std.testing.expectEqual(@as(u64, 1), cache.stale);
    const again = cache.next(ram.view(), m85, 0).?;
    try std.testing.expectEqual(@as(u16, 0x2001), again.instr.hw1);
    try std.testing.expectEqual(@as(u16, 0x2207), cache.next(ram.view(), m85, 2).?.instr.hw1);
    try std.testing.expectEqual(@as(u64, 2), cache.formed);
}

test "a jump into the middle of a block starts a block there" {
    var ram: Ram = .{};
    straightRun(&ram);
    const cache = try freshCache();
    defer std.testing.allocator.destroy(cache);
    _ = cache.next(ram.view(), m85, 0).?;
    const mid = cache.next(ram.view(), m85, 4).?;
    try std.testing.expectEqual(@as(u16, 0xE7FA), mid.instr.hw1);
    try std.testing.expectEqual(@as(u64, 2), cache.formed);
}

test "an address that cannot be fetched is left to the step" {
    var ram: Ram = .{};
    const cache = try freshCache();
    defer std.testing.allocator.destroy(cache);
    try std.testing.expect(cache.next(ram.view(), m85, 64) == null);
}
