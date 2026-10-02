//! NPU_OP_POOL in MAX mode (pooling_mode 0): the largest IFM element in
//! each kernel window, clamped to ACTIVATION_MIN/MAX, written to the OFM.
//!
//! KERNEL_WIDTH_M1 (0x120), KERNEL_HEIGHT_M1 (0x121) and KERNEL_STRIDE
//! (0x122) follow the Ethos-U55 TRM (102420_0200_02, cmd0 table): the
//! stride-1 low bits in b0 (x) and b1 (y), (stride-1)>>1 in b[8:6] (x) and
//! b[11:9] (y), with a supported stride of 1 to 3. Arm's Vela 3.12.0
//! `generate_kernel` writes the same, plus dilation-1 in b3 (x) and b4 (y).
//! b2 picks the block traversal, which changes the order of work but not
//! the result. A stride outside 1 to 3 is refused.
//!
//! Like MIN/MAX this models only what holds whatever the hardware does
//! inside: IFM and OFM of one type (int8, uint8 or int16) sharing a zero
//! point, no IFM padding, no dilation, no LUT, tanh or sigmoid activation.
//! AVERAGE, REDUCE_SUM, padding and mixed zero points are
//! error.OperatorNotModelled rather than a guess.
const regs = @import("npu_vela_regs.zig");
const dma = @import("npu_vela_dma.zig");
const fm = @import("npu_vela_fm.zig");
const quant = @import("npu_vela_quant.zig");
const addr = @import("npu_vela_addr.zig");
const minmax = @import("npu_vela_minmax.zig");

pub const mode_max: u16 = 0;

pub const Error = minmax.Error;

/// The kernel registers, raw.
pub const State = struct {
    width_m1: u16 = 0,
    height_m1: u16 = 0,
    stride: u16 = 0,
};

pub const Outcome = enum { applied, not_modelled };

/// Apply one cmd0 register set to `state`.
pub fn apply(state: *State, code: u10, param: u16) Outcome {
    const slot: *u16 = switch (code) {
        0x120 => &state.width_m1,
        0x121 => &state.height_m1,
        0x122 => &state.stride,
        else => return .not_modelled,
    };
    slot.* = param;
    return .applied;
}

pub const Step = struct { x: u32, y: u32 };

/// The kernel's stride in elements, from KERNEL_STRIDE.
pub fn step(raw: u16) Step {
    return .{
        .x = 1 + ((raw & 1) | ((raw >> 6) & 7) << 1),
        .y = 1 + (((raw >> 1) & 1) | ((raw >> 9) & 7) << 1),
    };
}

/// The TRM's supported stride range, on both axes.
pub const max_step: u32 = 3;

/// Everything the operator reads, as the program left it.
pub const Inputs = struct {
    bases: regs.State,
    maps: fm.State,
    quant: quant.State,
    kernel: State,
};

const dilation_bits: u16 = (1 << 3) | (1 << 4);

fn supported(inputs: Inputs) Error!addr.Format {
    const maps = inputs.maps;
    const pad = maps.ifm_pad;
    if (inputs.quant.activation != 0) return error.OperatorNotModelled;
    if (inputs.kernel.stride & dilation_bits != 0) return error.OperatorNotModelled;
    const s = step(inputs.kernel.stride);
    if (s.x > max_step or s.y > max_step) return error.OperatorNotModelled;
    if (pad.top != 0 or pad.left != 0 or pad.right != 0 or pad.bottom != 0) return error.OperatorNotModelled;
    if (maps.ifm.zero_point != maps.ofm.zero_point) return error.OperatorNotModelled;
    const ifm = addr.ifmFormat(maps.ifm.precision) orelse return error.OperatorNotModelled;
    const ofm = addr.ofmFormat(maps.ofm.precision) orelse return error.OperatorNotModelled;
    if (ifm.size > 2 or ifm.size != ofm.size or ifm.signed != ofm.signed) return error.OperatorNotModelled;
    if (ifm.layout != ofm.layout) return error.OperatorNotModelled;
    return ifm;
}

/// The largest IFM element in the window whose output is (y, x, c).
fn window(memory: anytype, regions: *const dma.Regions, inputs: Inputs, f: addr.Format, y: u32, x: u32, c: u32) Error!i32 {
    const maps = inputs.maps;
    const k = inputs.kernel;
    const s = step(k.stride);
    var best: i32 = undefined;
    for (0..@as(u32, k.height_m1) + 1) |ky| for (0..@as(u32, k.width_m1) + 1) |kx| {
        const iy = y * s.y + @as(u32, @intCast(ky));
        const ix = x * s.x + @as(u32, @intCast(kx));
        const at = addr.address(inputs.bases.ifm, maps.ifm, inputs.quant.ifm_stride, f, iy, ix, c);
        const v = try minmax.load(memory, try minmax.location(regions, maps.ifm.region, at, f.size), f);
        best = if (ky == 0 and kx == 0) v else @max(best, v);
    };
    return best;
}

/// Run one MAX pool over the whole OFM. Returns the elements written.
pub fn run(memory: anytype, regions: *const dma.Regions, mode: u16, inputs: Inputs) Error!u64 {
    if (mode != mode_max) return error.OperatorNotModelled;
    const f = try supported(inputs);
    const maps = inputs.maps;
    const q = inputs.quant;
    const low = minmax.signExtend(q.activation_min, f);
    const high = minmax.signExtend(q.activation_max, f);
    const shape = maps.ofmShape();
    var written: u64 = 0;
    for (0..shape.height) |y| for (0..shape.width) |x| for (0..shape.depth) |c| {
        const yy: u32 = @intCast(y);
        const xx: u32 = @intCast(x);
        const cc: u32 = @intCast(c);
        const top = try window(memory, regions, inputs, f, yy, xx, cc);
        const o_at = addr.address(inputs.bases.ofm, maps.ofm, q.ofm_stride, f, yy, xx, cc);
        try minmax.store(memory, try minmax.location(regions, maps.ofm.region, o_at, f.size), @min(@max(top, low), high), f);
        written += 1;
    };
    return written;
}
