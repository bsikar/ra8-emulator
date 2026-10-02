//! Tests for src/periph/npu/npu_vela_dma.zig: the region decode and the
//! linear copy NPU_OP_DMA_START does.
const std = @import("std");
const ra8 = @import("ra8");
const dma = ra8.periph.npu_vela.dma;

/// A flat 4 KiB memory at bus address 0x1000 that refuses everything else.
const Memory = struct {
    bytes: [4096]u8 = [_]u8{0} ** 4096,

    const base: u32 = 0x1000;

    fn slot(self: *Memory, address: u32, len: usize) error{Refused}![]u8 {
        if (address < base or address - base + len > self.bytes.len) return error.Refused;
        return self.bytes[address - base ..][0..len];
    }

    pub fn read(self: *Memory, address: u32, into: []u8) error{Refused}!void {
        @memcpy(into, try self.slot(address, into.len));
    }

    pub fn write(self: *Memory, address: u32, bytes: []const u8) error{Refused}!void {
        @memcpy(try self.slot(address, bytes.len), bytes);
    }
};

const regions: dma.Regions = .{ 0x1000, 0x1800, 0, 0, 0, 0, 0, 0 };

test "a region parameter splits into index, internal and stride" {
    try std.testing.expectEqual(dma.Region{ .index = 3, .internal = true, .stride = 2 }, dma.Region.fromParam(0x0503));
    try std.testing.expectEqual(dma.Region{}, dma.Region.fromParam(0));
}

test "a 1D copy moves bytes between regions, offsets added to BASEP" {
    var memory = Memory{};
    for (memory.bytes[0x10..0x210], 0..) |*b, i| b.* = @truncate(i);
    const moved = try dma.copy(&memory, &regions, .{ .index = 0 }, .{ .index = 1 }, .{ .src = 0x10, .dst = 0x20, .len = 0x200 });
    try std.testing.expectEqual(@as(u64, 0x200), moved);
    try std.testing.expectEqualSlices(u8, memory.bytes[0x10..0x210], memory.bytes[0x820..0xA20]);
}

test "a zero-length copy moves nothing" {
    var memory = Memory{};
    try std.testing.expectEqual(@as(u64, 0), try dma.copy(&memory, &regions, .{}, .{ .index = 1 }, .{}));
}

test "a copy that runs off memory stops with Refused after the chunks before it" {
    var memory = Memory{};
    @memset(memory.bytes[0..0x300], 0xAA);
    const result = dma.copy(&memory, &regions, .{}, .{ .index = 1 }, .{ .dst = 0x700, .len = 0x200 });
    try std.testing.expectError(error.Refused, result);
    try std.testing.expectEqual(@as(u8, 0xAA), memory.bytes[0xFFF]);
}

test "2D strides, internal memory and bad regions are refused by name" {
    var memory = Memory{};
    const plain = dma.Region{};
    try std.testing.expectError(error.StrideNotModelled, dma.copy(&memory, &regions, .{ .stride = 1 }, plain, .{ .len = 4 }));
    try std.testing.expectError(error.InternalNotModelled, dma.copy(&memory, &regions, plain, .{ .internal = true }, .{ .len = 4 }));
    try std.testing.expectError(error.RegionOutOfRange, dma.copy(&memory, &regions, .{ .index = 8 }, plain, .{ .len = 4 }));
}

test "an address past 32 bits is refused before any access" {
    var memory = Memory{};
    try std.testing.expectError(error.AddressTooHigh, dma.copy(&memory, &regions, .{}, .{}, .{ .src = 0xFFFF_FFFF, .len = 4 }));
}
