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

/// A real Vela 3.12.0 stream (ethos-u55-256): TFLite MAXIMUM, int8 1x4x4x8,
/// both inputs and the output at scale 0.05, zero point -3. IFM at region 1
/// offset 0x00, IFM2 at 0x80, and the OFM written in place over the IFM.
/// The 324 bytes after the 32-byte driver header, as Vela emitted them.
const vela_max = [_]u32{
    0x00004024, 0x00000001, 0x0001010F, 0x00004000, 0x00000000, 0x00004001,
    0x00000000, 0x00004002, 0x00000000, 0x00004003, 0x00000000, 0x0003010B,
    0x0003010C, 0x0003010A, 0x00070104, 0x00004006, 0x00000001, 0x00004005,
    0x00000020, 0x00004004, 0x00000008, 0xFFFD0109, 0x00010105, 0x00000107,
    0x0001011F, 0x00004010, 0x00000000, 0x00004011, 0x00000000, 0x00004012,
    0x00000000, 0x00004013, 0x00000000, 0x0003011B, 0x0003011C, 0x0003011A,
    0x00030112, 0x00030111, 0x00070113, 0x00004016, 0x00000001, 0x00004015,
    0x00000020, 0x00004014, 0x00000008, 0xFFFD0118, 0x00010114, 0x00000125,
    0xFF800126, 0x007F0127, 0x00030116, 0x00030115, 0x00070117, 0x002E010D,
    0x002E012D, 0x000A018D, 0x00000124, 0x0001018F, 0x00004080, 0x00000080,
    0x00004081, 0x00000000, 0x00004082, 0x00000000, 0x00004083, 0x00000000,
    0x0003018B, 0x0003018C, 0x0003018A, 0x00004086, 0x00000001, 0x00004085,
    0x00000020, 0x00004084, 0x00000008, 0xFFFD0189, 0x00010185, 0x00000180,
    0x0000012F, 0x00040006, 0xFFFF0000,
};

test "a Vela-compiled MAXIMUM runs to its STOP and writes the larger of each pair" {
    var memory = Memory{};
    var a: [128]i8 = undefined;
    var b: [128]i8 = undefined;
    for (&a, &b, 0..) |*x, *y, i| {
        x.* = @bitCast(@as(u8, @truncate(i * 37 + 11)));
        y.* = @bitCast(@as(u8, @truncate(i * 91 + 200)));
    }
    @memcpy(memory.bytes[0x800..0x880], std.mem.asBytes(&a));
    @memcpy(memory.bytes[0x880..0x900], std.mem.asBytes(&b));
    const result = try vela.runner.run(&memory, &regions, &vela_max);
    try std.testing.expectEqual(@as(u64, 128), result.elements);
    for (a, b, 0..) |x, y, i| {
        try std.testing.expectEqual(@max(x, y), @as(i8, @bitCast(memory.bytes[0x800 + i])));
    }
}
