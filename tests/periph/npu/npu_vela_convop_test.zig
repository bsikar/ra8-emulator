//! Tests for src/periph/npu/npu_vela_convop.zig: NPU_OP_CONV driven by real
//! Vela 3.12.0 streams (ethos-u55-256) through the runner, so the register
//! decode, the weight and record loads and the IFM/OFM addressing are all
//! exercised. The 1x1 case lives in npu_vela_run_test.zig; this file holds
//! the cases that need padding, stride and a kernel bigger than one tap,
//! and the depthwise case.
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

fn hexBytes(comptime hex: []const u8) [hex.len / 2]u8 {
    @setEvalBranchQuota(100_000);
    var out: [hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

/// TFLite CONV_2D, 3x3 kernel, stride 2, SAME padding, per-channel int8:
/// 1x6x6x8 in (zero point -5) to 1x3x3x6 out (zero point 7). Vela pads one
/// row at the bottom and one column at the right (IFM_PAD_BOTTOM/RIGHT 1),
/// sets KERNEL_STRIDE 7 (both strides 2, part-kernel-first), DMAs flash
/// 0x40 (0x250 bytes) to region 1 offset 0x160, and runs the conv with the
/// IFM at region 1 offset 0x000 and the OFM at 0x120. The 336 bytes after
/// the 32-byte driver header, as Vela emitted them.
const vela_conv3x3 = [_]u32{
    0x00000130, 0x00004030, 0x00000040, 0x00010131, 0x00004031, 0x00000160,
    0x00004032, 0x00000250, 0x00000010, 0x0001010F, 0x00004000, 0x00000000,
    0x00004001, 0x00000000, 0x00004002, 0x00000000, 0x00004003, 0x00000000,
    0x0005010B, 0x0005010C, 0x0005010A, 0x00070104, 0x00004006, 0x00000001,
    0x00004005, 0x00000030, 0x00004004, 0x00000008, 0xFFFB0109, 0x00010105,
    0x00000107, 0x00000100, 0x00000101, 0x00010103, 0x00010102, 0x0001011F,
    0x00004010, 0x00000120, 0x00004011, 0x00000000, 0x00004012, 0x00000000,
    0x00004013, 0x00000000, 0x0002011B, 0x0002011C, 0x0002011A, 0x00020112,
    0x00020111, 0x00050113, 0x00004016, 0x00000001, 0x00004015, 0x00000012,
    0x00004014, 0x00000006, 0x00070118, 0x00010114, 0x00020121, 0x00020120,
    0x00070122, 0x00010128, 0x00004020, 0x000001A0, 0x00004021, 0x00000210,
    0x00010129, 0x00004022, 0x00000160, 0x00004023, 0x00000040, 0x00000125,
    0xFF800126, 0x007F0127, 0x00030116, 0x00030115, 0x00070117, 0x000A010D,
    0x001E012D, 0x00000124, 0x0000012F, 0x00000011, 0x00000002, 0xFFFF0000,
};

/// The 0x250 flash bytes from offset 0x40: 64 bytes of scale records, then
/// 528 bytes of weight stream.
const flash = hexBytes("27f5ffffff5629cf69273c09000000002da4522606f7fffffff6f4ef7428aefdffffff62d1284026d8080000004630b3" ++
    "52269efaffffff723636592600000000680ddc010c009bd2a284a097b92700e047469087f6b6e40800338f5091efe20f" ++
    "405b36e53a60cdd43400d09a0d02782a6bebf6ff6c0515ac821acabb0f80ce4c05b28360c70a0038a5ab4dfa5b8aa100" ++
    "202e4da7b906d9330b00f04c714c0208dece42506e8a3d0f4ddbf0cff421bbcec0cf04f50f5f75ecc41636c305000000" ++
    "cf22e78156bf38c800bcdc662a0262af004056813d3ddb319707f0dbbc912aa153e0c1ff4f7838bfe5d9211105002622" ++
    "5129a4777fe500d0f2da44b38c80230b001febdb67f0907b13f8e1e4aba779b89d0070bdef4dfb13e1fcfbffa9bd995b" ++
    "1615a21d0ff0c8a6959414968b0600906395683fbbb27000f07d162a6e9615240400e7a15f7c1908b94e86e2b52bf0a4" ++
    "bf85f03f1005813530a579f30fddfcd6efdf64b65c000000091d3232bc37d998ac2bd0539753dc0900c082471022a175" ++
    "9103f0b9dd641140f884dcffaff4b882a00e4ff80000e8c54f29800c9c890050296abe07da47f5010062195998ea003b" ++
    "bea82767c8391cd93600208c12fd7a44c83bf5ff0ab3bc453647ce360fc0e0ce7776e0c3e70c00ddd30a947eaf2ba600" ++
    "508db0fe1097084003005c67b9d0c6a64e03752eb876f5651f60f06f8ba4d976654d76fb0f354f07d9d794353f000400" ++
    "c1e9ed3def33ed53f4390bb094ec791f00e0121c854a8589590b004018852a00ee8dcbbdc2e92ab86b03009cff7fe1ff" ++
    "01fcffffffffffffffffffffffffffff");
const ifm = hexBytes("61f1e1115468ccc10716c0db6d415a0be0b32c04eabd018c8e9c5bd79e837145a74d1385a00633eea6e65b9224701fcb" ++
    "bb6e29e79ab5f4c0c1bfb14efc542a4e2ac4c7cbb60973364b34db57c5438a032a319a438ab1927a0109f722b62bec35" ++
    "0e96f3933acc7fa10d3ffaf83aae44e78ab2f53f35e60a5a6b3515f604136c7f623886ec43e5285afa211d31c5a9c3f1" ++
    "6f84390935858d26b4a5e19322aac1ea1cfd25c01d1fb81bc9b71ae10d6e6bfeb650d12e9d26f662ad8bfc0de2654a0c" ++
    "df849f70383d25e149ae50859f6e3c5526a0b7a9d835eea3f4129adc571364241bcceccc27b04e75c5f03f9057fed726" ++
    "2564b3d37f49db2b066d83d5f0b3bf82680de518dfe4eb645fbd934ea36993f0188a8913fa26e573b55ff1f3d72caeb4");
/// TFLite Micro's double-rounding output for that IFM; tflite-runtime
/// agrees on every byte.
const ofm = hexBytes("80f813c1f280794d3680657f24bed27f154d808809802380807f34805ea7408014567fd9057ff61144807f803ce85dcd" ++
    "3fb5000f23a5");

test "a Vela-compiled 3x3 stride-2 SAME conv writes TFLite Micro's output" {
    var memory = Memory{};
    @memcpy(memory.bytes[0x40..][0..flash.len], &flash);
    @memcpy(memory.bytes[0x800..][0..ifm.len], &ifm);
    const result = try vela.runner.run(&memory, &regions, &vela_conv3x3);
    try std.testing.expectEqual(@as(u64, 0x250), result.moved);
    try std.testing.expectEqual(@as(u64, 54), result.elements);
    try std.testing.expectEqualSlices(u8, &ofm, memory.bytes[0x920..][0..ofm.len]);
}

test "a conv with dilation set is not modelled" {
    var memory = Memory{};
    @memcpy(memory.bytes[0x40..][0..flash.len], &flash);
    var words = vela_conv3x3;
    words[60] |= (1 << 3) << 16; // KERNEL_STRIDE parameter: x dilation 2
    try std.testing.expectError(error.OperatorNotModelled, vela.runner.run(&memory, &regions, &words));
}

test "a corrupt weight stream is refused as BadWeights" {
    var memory = Memory{};
    @memcpy(memory.bytes[0x40..][0..flash.len], &flash);
    var words = vela_conv3x3;
    words[65] = 0x0000_0010; // WEIGHT_LENGTH payload 0x210 -> 0x10: the stream runs out
    try std.testing.expectError(error.BadWeights, vela.runner.run(&memory, &regions, &words));
}

/// TFLite DEPTHWISE_CONV_2D, 3x3 kernel, stride 2, SAME padding, depth
/// multiplier 1, per-channel int8: 1x6x6x8 in (zero point -5) to 1x3x3x8
/// out (zero point 7). Vela pads one row at the bottom and one column at
/// the right, sets KERNEL_STRIDE 3 (both strides 2), DMAs flash 0x50 (0xD0
/// bytes) to region 1 offset 0x170, and runs NPU_OP_DEPTHWISE with the IFM
/// at region 1 offset 0x000 and the OFM at 0x120. The 336 bytes after the
/// 32-byte driver header, as Vela emitted them.
const vela_depthwise = [_]u32{
    0x00000130, 0x00004030, 0x00000050, 0x00010131, 0x00004031, 0x00000170,
    0x00004032, 0x000000D0, 0x00000010, 0x0001010F, 0x00004000, 0x00000000,
    0x00004001, 0x00000000, 0x00004002, 0x00000000, 0x00004003, 0x00000000,
    0x0005010B, 0x0005010C, 0x0005010A, 0x00070104, 0x00004006, 0x00000001,
    0x00004005, 0x00000030, 0x00004004, 0x00000008, 0xFFFB0109, 0x00010105,
    0x00000107, 0x00000100, 0x00000101, 0x00010103, 0x00010102, 0x0001011F,
    0x00004010, 0x00000120, 0x00004011, 0x00000000, 0x00004012, 0x00000000,
    0x00004013, 0x00000000, 0x0002011B, 0x0002011C, 0x0002011A, 0x00020112,
    0x00020111, 0x00070113, 0x00004016, 0x00000001, 0x00004015, 0x00000018,
    0x00004014, 0x00000008, 0x00070118, 0x00010114, 0x00020121, 0x00020120,
    0x00030122, 0x00010128, 0x00004020, 0x000001C0, 0x00004021, 0x00000080,
    0x00010129, 0x00004022, 0x00000170, 0x00004023, 0x00000050, 0x00000125,
    0xFF800126, 0x007F0127, 0x00030116, 0x00030115, 0x00070117, 0x000A010D,
    0x001E012D, 0x00000124, 0x0000012F, 0x00000011, 0x00000003, 0xFFFF0000,
};

/// The 0xD0 flash bytes from offset 0x50: 80 bytes of scale records, then
/// 128 bytes of weight stream.
const dw_flash = hexBytes("17faffffff6fcee9642644fbffffff2e57715226b3ffffffff5cb5235526aa05000000fb74dc632623fbffffff9990c0" ++
    "73273405000000719e475d269a030000006dde1f6a2668f9ffffffcfd28d5b28300254f4bdcefb27c584c3f2a0f02f1f" ++
    "ff8e2e0ecead9d5d1dfd8c7c6c9cfb7a5a3afae989b900f0e25dfa4ffebb0c1e0300ad00f56d3be2ceaa6b0dd98d11e7" ++
    "1b00dc81d099d9d20600a07553a7920dab090fe325a91cc700c0fef9023bcc0e7000b8e3c959422000c8829681607c65" ++
    "008012000735feffffffffffffffffff");
const dw_ifm = hexBytes("61f1e1115468ccc10716c0db6d415a0be0b32c04eabd018c8e9c5bd79e837145a74d1385a00633eea6e65b9224701fcb" ++
    "bb6e29e79ab5f4c0c1bfb14efc542a4e2ac4c7cbb60973364b34db57c5438a032a319a438ab1927a0109f722b62bec35" ++
    "0e96f3933acc7fa10d3ffaf83aae44e78ab2f53f35e60a5a6b3515f604136c7f623886ec43e5285afa211d31c5a9c3f1" ++
    "6f84390935858d26b4a5e19322aac1ea1cfd25c01d1fb81bc9b71ae10d6e6bfeb650d12e9d26f662ad8bfc0de2654a0c" ++
    "df849f70383d25e149ae50859f6e3c5526a0b7a9d835eea3f4129adc571364241bcceccc27b04e75c5f03f9057fed726" ++
    "2564b3d37f49db2b066d83d5f0b3bf82680de518dfe4eb645fbd934ea36993f0188a8913fa26e573b55ff1f3d72caeb4");
/// TFLite Micro's double-rounding output for that IFM; tflite-runtime
/// agrees on every byte.
const dw_ofm = hexBytes("0ba13811005c80eb7f09f37ff02a05f3c5dfaf6d2814ec25d9ffd982da85eff780b376e1dd421ded01d30ef3f837501e" ++
    "10185e25b52cdc02556f7f7a113ed908110ee72ffc0b151c");

test "a Vela-compiled 3x3 stride-2 SAME depthwise conv writes TFLite Micro's output" {
    var memory = Memory{};
    @memcpy(memory.bytes[0x50..][0..dw_flash.len], &dw_flash);
    @memcpy(memory.bytes[0x800..][0..dw_ifm.len], &dw_ifm);
    const result = try vela.runner.run(&memory, &regions, &vela_depthwise);
    try std.testing.expectEqual(@as(u64, 0xD0), result.moved);
    try std.testing.expectEqual(@as(u64, 72), result.elements);
    try std.testing.expectEqualSlices(u8, &dw_ofm, memory.bytes[0x920..][0..dw_ofm.len]);
}
