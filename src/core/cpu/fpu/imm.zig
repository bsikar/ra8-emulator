//! VFPExpandImm from the Arm ARM (DDI0553): the eight-bit immediate of
//! VMOV (immediate) widened to a single or double. imm8 = a:b:cd:efgh
//! gives sign a, an exponent of NOT(b), then b repeated, then cd, and a
//! fraction that starts with efgh. Every value is (-1)^a * (16 + efgh) / 16
//! * 2^(NOT(b):cd - 3), so 0x70 is 1.0 and 0x00 is 2.0.
const std = @import("std");
const Format = @import("format.zig").Format;

pub fn expandImm(comptime fmt: Format, imm8: u8) fmt.Bits() {
    const e: u6 = fmt.exp_bits;
    const f: u7 = fmt.frac_bits;
    const b: u64 = imm8 >> 6 & 1;
    const repeated: u64 = if (b == 1) (@as(u64, 1) << (e - 3)) - 1 else 0;
    const exp: u64 = (b ^ 1) << (e - 1) | repeated << 2 | (imm8 >> 4 & 3);
    const frac: u64 = @as(u64, imm8 & 0xF) << @intCast(f - 4);
    return fmt.pack(@intCast(imm8 >> 7), @intCast(exp), @intCast(frac));
}
