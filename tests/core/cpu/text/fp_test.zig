//! Arm ARM syntax vectors for the floating-point instruction groups.
const v81m = @import("v81m.zig");

test "floating arithmetic group" {
    try v81m.expectTexts(&.{.{ .hw1 = 0xEE30, .hw2 = 0x0A81, .text = "vadd.f32 s0, s1, s2" }});
}
test "unary FP group" {
    try v81m.expectTexts(&.{.{ .hw1 = 0xEEF0, .hw2 = 0x0A41, .text = "vmov.f32 s1, s2" }});
}
test "FP system compare group" {
    try v81m.expectTexts(&.{.{ .hw1 = 0xEEB4, .hw2 = 0x0A60, .text = "vcmp.f32 s0, s1" }});
}
test "FP conversion group" {
    try v81m.expectTexts(&.{.{ .hw1 = 0xEEB7, .hw2 = 0x0AE0, .text = "vcvt.f64.f32 d0, s1" }});
}
test "directed FP selection group" {
    try v81m.expectTexts(&.{.{ .hw1 = 0xFE00, .hw2 = 0x0A81, .text = "vseleq.f32 s0, s1, s2" }});
}
test "core to FP register move group" {
    try v81m.expectTexts(&.{.{ .hw1 = 0xEE00, .hw2 = 0x2A90, .text = "vmov s1, r2" }});
}
test "FP memory group" {
    try v81m.expectTexts(&.{.{ .hw1 = 0xED90, .hw2 = 0x1A01, .text = "vldr.f32 s2, [r0, #4]" }});
}
test "FP unary absolute operation" {
    try v81m.expectTexts(&.{.{ .hw1 = 0xEEB0, .hw2 = 0x0BC1, .text = "vabs.f64 d0, d1" }});
}
test "FP status transfer" {
    try v81m.expectTexts(&.{.{ .hw1 = 0xEEF1, .hw2 = 0x0A10, .text = "vmrs r0, fpscr" }});
}
test "FP int and fixed conversion syntax" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xEEBD, .hw2 = 0x0AE0, .text = "vcvt.s32.f32 s0, s1" },
        .{ .hw1 = 0xEEBE, .hw2 = 0x0AC8, .text = "vcvt.s32.f32 s0, s0, #16" },
        .{ .hw1 = 0xEEBB, .hw2 = 0x1B44, .text = "vcvt.f64.u16 d1, d1, #8" },
        .{ .hw1 = 0xEEB2, .hw2 = 0x0A60, .text = "vcvtb.f32.f16 s0, s1" },
    });
}
test "directed FP rounding syntax" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xFE80, .hw2 = 0x0A81, .text = "vmaxnm.f32 s0, s1, s2" },
        .{ .hw1 = 0xFEBC, .hw2 = 0x0AE0, .text = "vcvta.s32.f32 s0, s1" },
        .{ .hw1 = 0xFEB8, .hw2 = 0x0A60, .text = "vrinta.f32 s0, s1" },
        .{ .hw1 = 0xEEB6, .hw2 = 0x0A60, .text = "vrintz.f32 s0, s1" },
    });
}
test "FP single register pair transfer" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xEC41, .hw2 = 0x0A11, .text = "vmov s2, s3, r0, r1" },
        .{ .hw1 = 0xEC55, .hw2 = 0x4A1F, .text = "vmov r4, r5, s30, s31" },
    });
}
test "FP store syntax" {
    try v81m.expectTexts(&.{.{ .hw1 = 0xEDC0, .hw2 = 0x0A01, .text = "vstr.f32 s1, [r0, #4]" }});
}
test "FP system register spellings" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xEEE1, .hw2 = 0x0A10, .text = "vmsr fpscr, r0" },
        .{ .hw1 = 0xEEF1, .hw2 = 0xFA10, .text = "vmrs apsr_nzcv, fpscr" },
        .{ .hw1 = 0xEEFC, .hw2 = 0x0A10, .text = "vmrs r0, vpr" },
    });
}
test "FP compare with zero" {
    try v81m.expectTexts(&.{.{ .hw1 = 0xEEB5, .hw2 = 0x1A40, .text = "vcmp.f32 s2, #0.0" }});
}
test "FP double register move" {
    try v81m.expectTexts(&.{.{ .hw1 = 0xEC47, .hw2 = 0x6B13, .text = "vmov d3, r6, r7" }});
}
test "FP multiple and negative-offset memory syntax" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xECC2, .hw2 = 0x1A03, .text = "vstmia r2, {s3-s5}" },
        .{ .hw1 = 0xED11, .hw2 = 0x1B02, .text = "vldr.f64 d1, [r1, #-8]" },
    });
}

test "FP immediate move expands the encoded value" {
    try v81m.expectTexts(&.{.{ .hw1 = 0xEEB7, .hw2 = 0x0A00, .text = "vmov.f32 s0, #1.0" }});
}

test "FP half immediate move expands to its decimal value" {
    try v81m.expectTexts(&.{.{ .hw1 = 0xEEB7, .hw2 = 0x3900, .text = "vmov.f16 s6, #1.0" }});
}
test "FP directed double select and rounded conversion" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xFE31, .hw2 = 0x0B02, .text = "vselgt.f64 d0, d1, d2" },
        .{ .hw1 = 0xFEBF, .hw2 = 0x0B41, .text = "vcvtm.u32.f64 s0, d1" },
    });
}
test "FP stack aliases" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xED2D, .hw2 = 0x0B04, .text = "vpush {d0-d1}" },
        .{ .hw1 = 0xECBD, .hw2 = 0x0B04, .text = "vpop {d0-d1}" },
    });
}
test "FP arithmetic double precision" {
    try v81m.expectTexts(&.{.{ .hw1 = 0xEE33, .hw2 = 0x2B44, .text = "vsub.f64 d2, d3, d4" }});
}
test "float from integer conversion" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xEEB8, .hw2 = 0x0AE0, .text = "vcvt.f32.s32 s0, s1" },
        .{ .hw1 = 0xEEB8, .hw2 = 0x0B60, .text = "vcvt.f64.u32 d0, s1" },
    });
}
test "half precision groups use S registers and the f16 suffix" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xEE30, .hw2 = 0x0981, .text = "vadd.f16 s0, s1, s2" },
        .{ .hw1 = 0xEEB0, .hw2 = 0x09E0, .text = "vabs.f16 s0, s1" },
        .{ .hw1 = 0xFE00, .hw2 = 0x0981, .text = "vseleq.f16 s0, s1, s2" },
    });
}
test "half precision memory transfer" {
    try v81m.expectTexts(&.{.{ .hw1 = 0xEDC0, .hw2 = 0x0903, .text = "vstr.16 s1, [r0, #6]" }});
}

test "FP conversion and directed forms preserve rounding and register widths" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xEEB8, .hw2 = 0x1B60, .text = "vcvt.f64.u32 d1, s1" },
        .{ .hw1 = 0xEEB2, .hw2 = 0x0B60, .text = "vcvtb.f64.f16 d0, s1" },
        .{ .hw1 = 0xEEB3, .hw2 = 0x0AE0, .text = "vcvtt.f16.f32 s0, s1" },
        .{ .hw1 = 0xFEBC, .hw2 = 0x09E0, .text = "vcvta.s32.f16 s0, s1" },
        .{ .hw1 = 0xFEB9, .hw2 = 0x0960, .text = "vrintn.f16 s0, s1" },
    });
}
test "FP transfers name FPSCR aliases and context registers" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xEEF2, .hw2 = 0x3A10, .text = "vmrs r3, fpscr_nzcvqc" },
        .{ .hw1 = 0xEEED, .hw2 = 0x1A10, .text = "vmsr p0, r1" },
        .{ .hw1 = 0xEEEE, .hw2 = 0x5A10, .text = "vmsr fpcxt_ns, r5" },
    });
}
test "double immediate FP move expands the represented value" {
    try v81m.expectTexts(&.{.{ .hw1 = 0xEEB8, .hw2 = 0x1B00, .text = "vmov.f64 d1, #-2.0" }});
}
test "negative multiply add mnemonic follows the encoded operation" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xEE10, .hw2 = 0x0A40, .text = "vnmla.f32 s0, s0, s0, s0" },
        .{ .hw1 = 0xEE90, .hw2 = 0x0A40, .text = "vfnma.f32 s0, s0, s0, s0" },
    });
}
