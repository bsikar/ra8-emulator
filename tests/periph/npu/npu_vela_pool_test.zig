//! Tests for src/periph/npu/npu_vela_pool.zig: MAX pooling.
const std = @import("std");
const ra8 = @import("ra8");
const vela = ra8.periph.npu_vela;
const pool = vela.pool;

const Memory = struct {
    bytes: [0x200]u8 = .{0} ** 0x200,
    pub fn read(self: *@This(), at: u32, out: []u8) error{Refused}!void {
        if (at + out.len > self.bytes.len) return error.Refused;
        @memcpy(out, self.bytes[at..][0..out.len]);
    }
    pub fn write(self: *@This(), at: u32, data: []const u8) error{Refused}!void {
        if (at + data.len > self.bytes.len) return error.Refused;
        @memcpy(self.bytes[at..][0..data.len], data);
    }
};

test "the kernel registers land and the others are passed back" {
    var state = pool.State{};
    try std.testing.expectEqual(pool.Outcome.applied, pool.apply(&state, 0x120, 2));
    try std.testing.expectEqual(pool.Outcome.applied, pool.apply(&state, 0x121, 1));
    try std.testing.expectEqual(pool.Outcome.applied, pool.apply(&state, 0x122, 3));
    try std.testing.expectEqual(pool.Outcome.not_modelled, pool.apply(&state, 0x125, 0));
    try std.testing.expectEqual(pool.State{ .width_m1 = 2, .height_m1 = 1, .stride = 3 }, state);
}

test "KERNEL_STRIDE decodes the low and extension bits as Vela writes them" {
    try std.testing.expectEqual(pool.Step{ .x = 1, .y = 1 }, pool.step(0));
    try std.testing.expectEqual(pool.Step{ .x = 2, .y = 2 }, pool.step(3));
    try std.testing.expectEqual(pool.Step{ .x = 3, .y = 1 }, pool.step(1 << 6));
    try std.testing.expectEqual(pool.Step{ .x = 1, .y = 3 }, pool.step(1 << 9));
    // The TRM gives the extension field three bits; 1 to 3 is supported.
    try std.testing.expectEqual(pool.Step{ .x = 5, .y = 1 }, pool.step(2 << 6));
    try std.testing.expectEqual(pool.Step{ .x = 1, .y = 5 }, pool.step(2 << 9));
    // Block traversal (b2) changes the order of work, not the step.
    try std.testing.expectEqual(pool.Step{ .x = 2, .y = 1 }, pool.step(1 | 1 << 2));
}

/// A 1x3x1 int8 IFM pooled by a 1x2 kernel at stride 1 into a 1x2x1 OFM.
fn inputs() pool.Inputs {
    var maps = vela.fm.State{};
    maps.ifm = .{ .width0_m1 = 2, .depth_m1 = 0, .precision = 1 };
    maps.ofm = .{ .width0_m1 = 1, .depth_m1 = 0, .precision = 1 };
    maps.ofm_width_m1 = 1;
    const stride = vela.quant.Stride{ .x = 1, .y = 3, .c = 1 };
    const q = vela.quant.State{ .activation_min = 0xFF80, .activation_max = 0x007F, .ifm_stride = stride, .ofm_stride = stride };
    var bases: @FieldType(pool.Inputs, "bases") = .{};
    bases.ofm = .{ 0x100, 0, 0, 0 };
    return .{ .bases = bases, .maps = maps, .quant = q, .kernel = .{ .width_m1 = 1 } };
}

test "MAX pool slides the window and clamps to the activation range" {
    var memory = Memory{};
    for ([_]i8{ -7, 4, -2 }, 0..) |v, i| memory.bytes[i] = @bitCast(v);
    const regions: vela.dma.Regions = .{0} ** 8;
    try std.testing.expectEqual(@as(u64, 2), try pool.run(&memory, &regions, pool.mode_max, inputs()));
    try std.testing.expectEqual(@as(i8, 4), @as(i8, @bitCast(memory.bytes[0x100])));
    try std.testing.expectEqual(@as(i8, 4), @as(i8, @bitCast(memory.bytes[0x101])));
    var clamped = inputs();
    clamped.quant.activation_max = 2;
    _ = try pool.run(&memory, &regions, pool.mode_max, clamped);
    try std.testing.expectEqual(@as(i8, 2), @as(i8, @bitCast(memory.bytes[0x100])));
}

test "what the model cannot vouch for is refused, not guessed" {
    var memory = Memory{};
    const regions: vela.dma.Regions = .{0} ** 8;
    try std.testing.expectError(error.OperatorNotModelled, pool.run(&memory, &regions, 1, inputs()));
    var padded = inputs();
    padded.maps.ifm_pad.left = 1;
    try std.testing.expectError(error.OperatorNotModelled, pool.run(&memory, &regions, pool.mode_max, padded));
    var dilated = inputs();
    dilated.kernel.stride = 1 << 3;
    try std.testing.expectError(error.OperatorNotModelled, pool.run(&memory, &regions, pool.mode_max, dilated));
    var wide = inputs();
    wide.kernel.stride = 2 << 6; // x stride 5, past the TRM's 3
    try std.testing.expectError(error.OperatorNotModelled, pool.run(&memory, &regions, pool.mode_max, wide));
    var mixed = inputs();
    mixed.maps.ofm.zero_point = 5;
    try std.testing.expectError(error.OperatorNotModelled, pool.run(&memory, &regions, pool.mode_max, mixed));
    try std.testing.expectEqual(@as(u8, 0), memory.bytes[0x100]);
}
