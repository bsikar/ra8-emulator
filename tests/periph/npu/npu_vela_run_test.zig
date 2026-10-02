//! Tests for src/periph/npu/npu_vela_run.zig: a Vela stream run end to end
//! as far as register state and DMA go.
const std = @import("std");
const ra8 = @import("ra8");
const vela = ra8.periph.npu_vela;

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

const regions: vela.dma.Regions = .{ 0x1000, 0x1800, 0, 0, 0, 0, 0, 0 };

/// Region 0 to region 1, 0x40 bytes from offset 0x10 to offset 0x20.
const dma_program = [_]u32{
    0x0000_0130, // DMA0_SRC_REGION region 0
    0x0001_0131, // DMA0_DST_REGION region 1
    0x0000_4030, 0x0000_0010, // DMA0_SRC
    0x0000_4031, 0x0000_0020, // DMA0_DST
    0x0000_4032, 0x0000_0040, // DMA0_LEN
    0x0000_0010, // DMA_START
    0x0000_0011, // DMA_WAIT
};

test "a DMA-only program moves its bytes between regions and stops" {
    var memory = Memory{};
    for (memory.bytes[0x10..0x50], 0..) |*b, i| b.* = @truncate(i + 1);
    const result = try vela.runner.run(&memory, &regions, &(dma_program ++ [_]u32{0x0000_0000}));
    try std.testing.expectEqual(@as(u64, 0x40), result.moved);
    try std.testing.expectEqualSlices(u8, memory.bytes[0x10..0x50], memory.bytes[0x820..0x860]);
    try std.testing.expectEqual(@as(u64, 0x40), result.state.dma0.len);
    try std.testing.expectEqual(@as(usize, 2), result.summary.register_sets);
}

test "a program with an operator stops before claiming it ran" {
    var memory = Memory{};
    const words = dma_program ++ [_]u32{ 0x0000_0002, 0x0000_0000 }; // CONV, STOP
    try std.testing.expectError(error.OperatorNotModelled, vela.runner.run(&memory, &regions, &words));
}

test "a malformed stream is refused before anything moves" {
    var memory = Memory{};
    @memset(memory.bytes[0..0x100], 0x5A);
    try std.testing.expectError(error.NoStop, vela.runner.run(&memory, &regions, &dma_program));
    try std.testing.expectEqual(@as(u8, 0), memory.bytes[0x820]);
}

test "a DMA the memory refuses surfaces as Refused" {
    var memory = Memory{};
    const far: vela.dma.Regions = .{ 0x1000, 0x9000, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectError(error.Refused, vela.runner.run(&memory, &far, &(dma_program ++ [_]u32{0x0000_0000})));
}
