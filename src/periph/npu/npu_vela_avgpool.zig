//! NPU_OP_POOL in AVERAGE mode (pooling_mode 1) without padding, for int8.
//!
//! The Ethos-U55 TRM (102420_0200_02, table 4-124 and cmd1 0x024) gives
//! average pool with pad=0 an int32 accumulator and the global OFM_SCALE.
//! Each output is the window sum of (ifm - IFM_ZERO_POINT), scaled by
//! OFM_SCALE under the OFM_PRECISION rounding mode, plus OFM_ZERO_POINT,
//! clamped to ACTIVATION_MIN/MAX. Vela 3.12.0 writes OFM_SCALE as
//! quantise_pooling_scale(kernel elements); for every kernel size from 1 to
//! 256 elements and every int8 window sum, that scale under TFL rounding
//! equals TFLite Micro's rounded division, and the tests replay a real Vela
//! stream against TFLM's bytes.
//!
//! Modelled: signed int8 IFM and OFM in one layout sharing a zero point,
//! the global scale (OFM_PRECISION b8), no padding, no dilation and no
//! activation function. Padded average pool (which the TRM runs without
//! scaling) and anything else is error.OperatorNotModelled.
const std = @import("std");
const dma = @import("npu_vela_dma.zig");
const addr = @import("npu_vela_addr.zig");
const minmax = @import("npu_vela_minmax.zig");
const pool = @import("npu_vela_pool.zig");
const round = @import("npu_vela_round.zig");

pub const mode_average: u16 = 1;

pub const Error = minmax.Error;

const global_scale: u16 = 1 << 8;
const dilation_bits: u16 = (1 << 3) | (1 << 4);

fn supported(inputs: pool.Inputs) Error!round.Rounding {
    const maps = inputs.maps;
    const q = inputs.quant;
    const pad = maps.ifm_pad;
    if (q.activation != 0 or inputs.kernel.stride & dilation_bits != 0) return error.OperatorNotModelled;
    const s = pool.step(inputs.kernel.stride);
    if (s.x > pool.max_step or s.y > pool.max_step) return error.OperatorNotModelled;
    if (pad.top != 0 or pad.left != 0 or pad.right != 0 or pad.bottom != 0) return error.OperatorNotModelled;
    if (maps.ifm.zero_point != maps.ofm.zero_point) return error.OperatorNotModelled;
    if (maps.ofm.precision & global_scale == 0 or q.ofm_scale.shift > 63) return error.OperatorNotModelled;
    const ifm = addr.ifmFormat(maps.ifm.precision) orelse return error.OperatorNotModelled;
    const ofm = addr.ofmFormat(maps.ofm.precision) orelse return error.OperatorNotModelled;
    if (!ifm.signed or !ofm.signed or ifm.size != 1 or ofm.size != 1) return error.OperatorNotModelled;
    if (ifm.layout != ofm.layout) return error.OperatorNotModelled;
    return round.Rounding.fromBits(addr.rounding(maps.ofm.precision)) orelse error.OperatorNotModelled;
}

/// The sum of (ifm - zero point) over the window whose output is (y, x, c).
fn windowSum(memory: anytype, regions: *const dma.Regions, inputs: pool.Inputs, f: addr.Format, zero_point: i32, y: u32, x: u32, c: u32) Error!i64 {
    const maps = inputs.maps;
    const k = inputs.kernel;
    const s = pool.step(k.stride);
    var sum: i64 = 0;
    for (0..@as(u32, k.height_m1) + 1) |ky| for (0..@as(u32, k.width_m1) + 1) |kx| {
        const iy = y * s.y + @as(u32, @intCast(ky));
        const ix = x * s.x + @as(u32, @intCast(kx));
        const at = addr.address(inputs.bases.ifm, maps.ifm, inputs.quant.ifm_stride, f, iy, ix, c);
        sum += try minmax.load(memory, try minmax.location(regions, maps.ifm.region, at, 1), f) - zero_point;
    };
    return sum;
}

/// One output element from a window sum.
pub fn average(sum: i64, scale: u32, shift: u6, rounding: round.Rounding, zero_point: i32, low: i32, high: i32) i32 {
    const scaled = round.apply(sum, scale, shift, rounding) + zero_point;
    return @intCast(std.math.clamp(scaled, low, high));
}

/// Run one AVERAGE pool over the whole OFM. Returns the elements written.
pub fn run(memory: anytype, regions: *const dma.Regions, inputs: pool.Inputs) Error!u64 {
    const rounding = try supported(inputs);
    const maps = inputs.maps;
    const q = inputs.quant;
    const f = addr.ifmFormat(maps.ifm.precision).?;
    const zp = minmax.signExtend(maps.ifm.zero_point, f);
    const low = @max(minmax.signExtend(q.activation_min, f), -128);
    const high = @min(minmax.signExtend(q.activation_max, f), 127);
    if (low > high) return error.OperatorNotModelled;
    const shape = maps.ofmShape();
    var written: u64 = 0;
    for (0..shape.height) |y| for (0..shape.width) |x| for (0..shape.depth) |c| {
        const yy: u32 = @intCast(y);
        const xx: u32 = @intCast(x);
        const cc: u32 = @intCast(c);
        const sum = try windowSum(memory, regions, inputs, f, zp, yy, xx, cc);
        const out = average(sum, q.ofm_scale.scale, @intCast(q.ofm_scale.shift), rounding, zp, low, high);
        const o_at = addr.address(inputs.bases.ofm, maps.ofm, q.ofm_stride, f, yy, xx, cc);
        try minmax.store(memory, try minmax.location(regions, maps.ofm.region, o_at, 1), out, f);
        written += 1;
    };
    return written;
}
