//! Elementwise MIN and MAX (NPU_OP_ELEMENTWISE modes 3 and 4) over two
//! input feature maps into the output, clamped to ACTIVATION_MIN/MAX.
//!
//! The Ethos-U55 TRM (102420_0200_02, table 4-126) requires IFM and OFM to
//! be the same type, one of int8, uint8 or int16, for MIN and MAX. The TRM
//! does not spell out how the zero points enter, so this models only the
//! case where IFM, IFM2 and OFM share one zero point: min and max then give
//! the same result whatever the hardware does with it. Anything else
//! (mixed zero points, a broadcast or scalar IFM2, a LUT, tanh or sigmoid
//! activation) is error.OperatorNotModelled rather than a guess.
const std = @import("std");
const regs = @import("npu_vela_regs.zig");
const dma = @import("npu_vela_dma.zig");
const fm = @import("npu_vela_fm.zig");
const quant = @import("npu_vela_quant.zig");
const addr = @import("npu_vela_addr.zig");

pub const mode_min: u16 = 3;
pub const mode_max: u16 = 4;

pub const Error = error{ OperatorNotModelled, RegionOutOfRange, AddressTooHigh, Refused };

/// Everything the operator reads, as the program left it.
pub const Inputs = struct {
    bases: regs.State,
    maps: fm.State,
    quant: quant.State,
};

fn format(inputs: Inputs) Error!addr.Format {
    const ifm = addr.ifmFormat(inputs.maps.ifm.precision) orelse return error.OperatorNotModelled;
    const ifm2 = addr.ifmFormat(inputs.maps.ifm2.precision) orelse return error.OperatorNotModelled;
    const ofm = addr.ofmFormat(inputs.maps.ofm.precision) orelse return error.OperatorNotModelled;
    if (ifm.size > 2 or ifm.signed != ofm.signed or ifm.size != ofm.size) return error.OperatorNotModelled;
    if (ifm2.signed != ifm.signed or ifm2.size != ifm.size) return error.OperatorNotModelled;
    if (ifm.layout != ofm.layout or ifm2.layout != ifm.layout) return error.OperatorNotModelled;
    return ifm;
}

fn supported(inputs: Inputs) Error!addr.Format {
    const maps = inputs.maps;
    if (maps.ifm2_broadcast != 0 or inputs.quant.activation != 0) return error.OperatorNotModelled;
    if (maps.ifm.zero_point != maps.ofm.zero_point or maps.ifm2.zero_point != maps.ofm.zero_point) {
        return error.OperatorNotModelled;
    }
    return format(inputs);
}

fn signExtend(raw: u16, f: addr.Format) i32 {
    if (!f.signed) return raw;
    return if (f.size == 1) @as(i8, @bitCast(@as(u8, @truncate(raw)))) else @as(i16, @bitCast(raw));
}

fn location(regions: *const dma.Regions, region: u16, offset: u64, size: u32) Error!u32 {
    if (region >= regions.len) return error.RegionOutOfRange;
    const at = regions[region] +% offset;
    if (at < offset or at + size > @as(u64, std.math.maxInt(u32)) + 1) return error.AddressTooHigh;
    return @intCast(at);
}

fn load(memory: anytype, at: u32, f: addr.Format) Error!i32 {
    var bytes: [2]u8 = .{ 0, 0 };
    memory.read(at, bytes[0..f.size]) catch return error.Refused;
    return signExtend(std.mem.readInt(u16, &bytes, .little), f);
}

fn store(memory: anytype, at: u32, value: i32, f: addr.Format) Error!void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, @truncate(@as(u32, @bitCast(value))), .little);
    memory.write(at, bytes[0..f.size]) catch return error.Refused;
}

/// One output element: MIN or MAX of the two inputs, then the clamp.
pub fn combine(mode: u16, a: i32, b: i32, low: i32, high: i32) i32 {
    const picked = if (mode == mode_min) @min(a, b) else @max(a, b);
    return @min(@max(picked, low), high);
}

/// Run one MIN or MAX over the whole OFM. Returns the elements written.
pub fn run(memory: anytype, regions: *const dma.Regions, mode: u16, inputs: Inputs) Error!u64 {
    if (mode != mode_min and mode != mode_max) return error.OperatorNotModelled;
    const f = try supported(inputs);
    const maps = inputs.maps;
    const q = inputs.quant;
    const low = signExtend(q.activation_min, f);
    const high = signExtend(q.activation_max, f);
    const shape = maps.ofmShape();
    var written: u64 = 0;
    for (0..shape.height) |y| for (0..shape.width) |x| for (0..shape.depth) |c| {
        const yy: u32 = @intCast(y);
        const xx: u32 = @intCast(x);
        const cc: u32 = @intCast(c);
        const a_at = addr.address(inputs.bases.ifm, maps.ifm, q.ifm_stride, f, yy, xx, cc);
        const b_at = addr.address(inputs.bases.ifm2, maps.ifm2, q.ifm2_stride, f, yy, xx, cc);
        const o_at = addr.address(inputs.bases.ofm, maps.ofm, q.ofm_stride, f, yy, xx, cc);
        const a = try load(memory, try location(regions, maps.ifm.region, a_at, f.size), f);
        const b = try load(memory, try location(regions, maps.ifm2.region, b_at, f.size), f);
        const out = combine(mode, a, b, low, high);
        try store(memory, try location(regions, maps.ofm.region, o_at, f.size), out, f);
        written += 1;
    };
    return written;
}
