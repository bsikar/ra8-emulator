//! MVE floating-point lane arithmetic (RA8EMU-23): VADD, VSUB and VMUL on
//! F16 and F32 lanes, as pure functions over Q register values.
//!
//! The Arm ARM (DDI0553) runs MVE floating point under StandardFPSCRValue:
//! round to nearest, default NaN and flush-to-zero for single precision,
//! with FPSCR.FZ16 and AHP kept. The cumulative flags still land in FPSCR.
//! A lane the predicate mask turns off keeps the destination's old bytes
//! and raises no flags, matching QEMU's DO_2OP_FP, which computes such a
//! lane on a scratch status.
const fpu = @import("../fpu/all.zig");
const Fpscr = fpu.fpscr.Fpscr;
const format = fpu.format;
const qreg = @import("qreg.zig");
const predicate = @import("predicate.zig");

/// The element widths MVE floating point works on.
pub const Size = enum { half, word };

pub const Op = enum { add, sub, mul };

/// StandardFPSCRValue: the controls MVE arithmetic runs under, flags clear.
pub fn standard(fpscr: Fpscr) Fpscr {
    return .{ .rmode = .nearest, .dn = 1, .fz = 1, .fz16 = fpscr.fz16, .ahp = fpscr.ahp };
}

/// Folds the cumulative flags `work` raised into `fpscr`.
pub fn accumulate(fpscr: *Fpscr, work: Fpscr) void {
    const cumulative = fpu.fpscr.mask.cumulative;
    fpscr.* = @bitCast(fpscr.bits() | (work.bits() & cumulative));
}

pub fn qsize(size: Size) qreg.Size {
    return if (size == .half) .half else .word;
}

/// `op` on every active lane of `a` and `b`, merged into `d` under `mask`.
pub fn binary(d: u128, a: u128, b: u128, size: Size, op: Op, mask: u16, fpscr: *Fpscr) u128 {
    const qs = qsize(size);
    var out = d;
    for (0..qreg.lanes(qs)) |i| {
        const e: u8 = @intCast(i);
        if (!predicate.active(mask, qs, e)) continue;
        var work = standard(fpscr.*);
        const x = qreg.elem(a, qs, e);
        const y = qreg.elem(b, qs, e);
        const r = switch (size) {
            .half => @as(u32, lane(format.half, op, @truncate(x), @truncate(y), &work)),
            .word => lane(format.single, op, x, y, &work),
        };
        out = qreg.setElem(out, qs, e, r);
        accumulate(fpscr, work);
    }
    return predicate.merge(d, out, mask);
}

fn lane(comptime fmt: format.Format, op: Op, x: fmt.Bits(), y: fmt.Bits(), work: *Fpscr) fmt.Bits() {
    return switch (op) {
        .add => fpu.add.add(fmt, x, y, work),
        .sub => fpu.add.sub(fmt, x, y, work),
        .mul => fpu.mul.mul(fmt, x, y, work),
    };
}
