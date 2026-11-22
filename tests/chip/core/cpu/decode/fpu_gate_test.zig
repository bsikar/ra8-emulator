//! Covers `src/chip/core/cpu/decode/fpu_gate.zig`: single-precision and no-FPU
//! decoding gates and UsageFault.UNDEFINSTR delivery.
const ra8 = @import("ra8");
const std = @import("std");

const decode = ra8.chip.core.cpu.decode;
const fixture = @import("../exception/ram.zig");
const Instr = ra8.chip.core.cpu.instr.Instr;
const memmap = ra8.chip.core.memmap;
const Profile = decode.profile.Profile;

const usage_handler: u32 = fixture.base + 0x1C0;
const usgfaultena: u32 = 1 << 18;
const undefinstr_bit: u32 = 1 << 16;

// Single-precision encodings (valid on .single and .double, refused on .none).
const vadd_f32 = [2]u16{ 0xEE30, 0x0A00 }; // VADD.F32 S0, S0, S0
const vsqrt_f32 = [2]u16{ 0xEEB1, 0x0AC0 }; // VSQRT.F32 S0, S0
const vcmp_f32 = [2]u16{ 0xEEB4, 0x0A40 }; // VCMP.F32 S0, S0
const vcvt_s32_f32 = [2]u16{ 0xEEBD, 0x0AC0 }; // VCVT.S32.F32 S0, S0
const vcvtb_f32_f16 = [2]u16{ 0xEEB2, 0x0A40 }; // VCVTB.F32.F16 S0, S0
const vpush_d8 = [2]u16{ 0xED2D, 0x8B02 }; // VPUSH {D8}
const vmov_d0_r0_r1 = [2]u16{ 0xEC41, 0x0B10 }; // VMOV D0, R0, R1

// Double-precision and FEAT_FP16 scalar encodings (valid on .double, refused on .single and .none).
const vadd_f64 = [2]u16{ 0xEE30, 0x0B00 }; // VADD.F64 D0, D0, D0
const vsqrt_f64 = [2]u16{ 0xEEB1, 0x0BC0 }; // VSQRT.F64 D0, D0
const vcmp_f64 = [2]u16{ 0xEEB4, 0x0B40 }; // VCMP.F64 D0, D0
const vcvt_f64_f32 = [2]u16{ 0xEEB7, 0x0AC0 }; // VCVT.F64.F32 D0, S0
const vcvt_f32_f64 = [2]u16{ 0xEEB7, 0x0BC0 }; // VCVT.F32.F64 S0, D0
const vcvt_s32_f64 = [2]u16{ 0xEEBD, 0x0BC0 }; // VCVT.S32.F64 S0, D0
const vrinta_f64 = [2]u16{ 0xFEB8, 0x0B40 }; // VRINTA.F64 D0, D0
const vadd_f16 = [2]u16{ 0xEE30, 0x0900 }; // VADD.F16 S0, S0, S0
const vmov_f16 = [2]u16{ 0xEE00, 0x0910 }; // VMOV.F16 S0, R0
const vldr_16 = [2]u16{ 0xED90, 0x0900 }; // VLDR.16 S0, [R0]

fn wide(hw: [2]u16) Instr {
    return .{ .address = fixture.code, .hw1 = hw[0], .hw2 = hw[1], .size = 4 };
}

test "single-precision profile accepts FPv5-SP encodings and rejects fp64 and scalar fp16" {
    const allowed_sp = [_][2]u16{
        vadd_f32, vsqrt_f32, vcmp_f32, vcvt_s32_f32, vcvtb_f32_f16, vpush_d8, vmov_d0_r0_r1,
    };
    for (allowed_sp) |hw| {
        try std.testing.expect(decode.decodeFor(Profile.m33, wide(hw)) != null);
        try std.testing.expect(!decode.refused(Profile.m33, wide(hw)));
    }

    const rejected_sp = [_][2]u16{
        vadd_f64,     vsqrt_f64,  vcmp_f64, vcvt_f64_f32, vcvt_f32_f64,
        vcvt_s32_f64, vrinta_f64, vadd_f16, vmov_f16,     vldr_16,
    };
    for (rejected_sp) |hw| {
        try std.testing.expect(decode.decodeFor(Profile.m85, wide(hw)) != null);
        try std.testing.expect(decode.decodeFor(Profile.m33, wide(hw)) == null);
        try std.testing.expect(decode.refused(Profile.m33, wide(hw)));
    }
}

test "no-FPU profile rejects all scalar FP encodings" {
    const no_fpu: Profile = .{ .v8_1m = false, .mve = false, .lob = false, .fpu = .none };
    const all_fp = [_][2]u16{
        vadd_f32, vsqrt_f32, vcmp_f32, vcvt_s32_f32, vpush_d8, vmov_d0_r0_r1, vadd_f64, vadd_f16,
    };
    for (all_fp) |hw| {
        try std.testing.expect(decode.decodeFor(no_fpu, wide(hw)) == null);
        try std.testing.expect(decode.refused(no_fpu, wide(hw)));
    }
}

test "M33 executing VADD.F64 or VCVT.F64.F32 takes UsageFault.UNDEFINSTR" {
    for ([_][2]u16{ vadd_f64, vcvt_f64_f32, vadd_f16 }) |hw| {
        var ram: fixture.Ram = .{};
        ram.putWord(fixture.base + 6 * 4, usage_handler | 1);
        ram.putWord(memmap.scb.shcsr, usgfaultena);
        ram.putHalf(fixture.code, hw[0]);
        ram.putHalf(fixture.code + 2, hw[1]);
        var cpu = try fixture.boot(&ram);
        cpu.profile = Profile.m33;
        cpu.fp.cpacr = 0x00F0_0000;
        try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
        try std.testing.expectEqual(usage_handler, cpu.regs.pc);
        try std.testing.expectEqual(undefinstr_bit, ram.word(memmap.scb.cfsr));
    }
}

test "FP16 scalar and MVE-I + FPU combinations decode independently" {
    const hx_sp_fp16: Profile = .{
        .v8_1m = true,
        .mve = false,
        .mve_fp = false,
        .lob = true,
        .pacbti = false,
        .fpu = .single,
        .fp16 = true,
    };
    for ([_][2]u16{ vadd_f16, vmov_f16, vldr_16, vadd_f32 }) |hw| {
        try std.testing.expect(decode.decodeFor(hx_sp_fp16, wide(hw)) != null);
    }
    try std.testing.expect(decode.decodeFor(hx_sp_fp16, wide(vadd_f64)) == null);
    for ([_][2]u16{ vadd_f16, vmov_f16, vldr_16 }) |hw| {
        try std.testing.expect(decode.decodeFor(Profile.m33, wide(hw)) == null);
    }

    const dp_mve_i: Profile = .{
        .v8_1m = true,
        .mve = true,
        .mve_fp = false,
        .lob = true,
        .pacbti = false,
        .fpu = .double,
        .fp16 = true,
    };
    const mve_fadd_f32 = [2]u16{ 0xEF00, 0x0D40 }; // VADD.F32 Q0, Q0, Q0
    const mve_vadd_i32 = [2]u16{ 0xEF22, 0x0844 }; // VADD.I32 Q0, Q1, Q2
    try std.testing.expect(decode.decodeFor(dp_mve_i, wide(vadd_f64)) != null);
    try std.testing.expect(decode.decodeFor(dp_mve_i, wide(mve_vadd_i32)) != null);
    try std.testing.expect(decode.decodeFor(dp_mve_i, wide(mve_fadd_f32)) == null);
    try std.testing.expect(decode.decodeFor(Profile.m55, wide(mve_fadd_f32)) != null);
}

test "VMRS/VMSR and VLDR sysreg transfers gate VPR/P0 on MVE and v8.1-M extensions on v8_1m" {
    const no_fpu_v81m: Profile = .{
        .v8_1m = true,
        .mve = false,
        .mve_fp = false,
        .lob = true,
        .fpu = .none,
        .fp16 = false,
    };
    const mve_i: Profile = .{ .v8_1m = true, .mve = true, .mve_fp = false, .lob = true, .fpu = .none, .fp16 = false };
    const m55_no_mve_dp: Profile = .{ .v8_1m = true, .mve = false, .mve_fp = false, .lob = true, .fpu = .double };
    const m55_no_mve_sp: Profile = .{ .v8_1m = true, .mve = false, .mve_fp = false, .lob = true, .fpu = .single };

    const fpscr_ops = [_][2]u16{ .{ 0xEEF1, 0x0A10 }, .{ 0xEEE1, 0x0A10 } };
    const vpr_p0_ops = [_][2]u16{
        .{ 0xEEFC, 0x0A10 }, .{ 0xEEEC, 0x0A10 },
        .{ 0xEEFD, 0x0A10 }, .{ 0xEEED, 0x0A10 },
    };
    const v81_fp_ops = [_][2]u16{
        .{ 0xEEF2, 0x0A10 }, .{ 0xEEE2, 0x0A10 },
        .{ 0xEEFE, 0x0A10 }, .{ 0xEEEE, 0x0A10 },
        .{ 0xEEFF, 0x0A10 }, .{ 0xEEEF, 0x0A10 },
    };
    const vldr_fpscr = [2]u16{ 0xED90, 0x1F80 };
    const vldr_vpr = [2]u16{ 0xEDD0, 0x4F80 };

    for (fpscr_ops) |hw| {
        try std.testing.expect(decode.decodeFor(Profile.m33, wide(hw)) != null);
        try std.testing.expect(decode.decodeFor(mve_i, wide(hw)) != null);
        try std.testing.expect(decode.refused(no_fpu_v81m, wide(hw)));
    }
    for (vpr_p0_ops) |hw| {
        try std.testing.expect(decode.refused(Profile.m33, wide(hw)));
        try std.testing.expect(decode.refused(m55_no_mve_sp, wide(hw)));
        try std.testing.expect(decode.refused(m55_no_mve_dp, wide(hw)));
        try std.testing.expect(decode.refused(no_fpu_v81m, wide(hw)));
        try std.testing.expect(decode.decodeFor(mve_i, wide(hw)) != null);
        try std.testing.expect(decode.decodeFor(Profile.m55, wide(hw)) != null);
    }
    for (v81_fp_ops) |hw| {
        try std.testing.expect(decode.refused(Profile.m33, wide(hw)));
        try std.testing.expect(decode.refused(no_fpu_v81m, wide(hw)));
        try std.testing.expect(decode.decodeFor(m55_no_mve_sp, wide(hw)) != null);
        try std.testing.expect(decode.decodeFor(m55_no_mve_dp, wide(hw)) != null);
        try std.testing.expect(decode.decodeFor(mve_i, wide(hw)) != null);
    }
    try std.testing.expect(decode.refused(Profile.m33, wide(vldr_fpscr)));
    try std.testing.expect(decode.refused(Profile.m33, wide(vldr_vpr)));
    try std.testing.expect(decode.refused(m55_no_mve_dp, wide(vldr_vpr)));
    try std.testing.expect(decode.refused(no_fpu_v81m, wide(vldr_fpscr)));
    try std.testing.expect(decode.decodeFor(m55_no_mve_dp, wide(vldr_fpscr)) != null);
    try std.testing.expect(decode.decodeFor(mve_i, wide(vldr_vpr)) != null);
}

test "M33 and M55-without-MVE take UsageFault.UNDEFINSTR on VMRS VPR or FPSCR_nzcvqc" {
    const m55_no_mve: Profile = .{ .v8_1m = true, .mve = false, .mve_fp = false, .lob = true, .fpu = .double };
    const cases = [_]struct { profile: Profile, hw: [2]u16 }{
        .{ .profile = Profile.m33, .hw = .{ 0xEEFC, 0x0A10 } },
        .{ .profile = Profile.m33, .hw = .{ 0xEEF2, 0x0A10 } },
        .{ .profile = m55_no_mve, .hw = .{ 0xEEFC, 0x0A10 } },
        .{ .profile = m55_no_mve, .hw = .{ 0xEEFD, 0x0A10 } },
    };
    for (cases) |c| {
        var ram: fixture.Ram = .{};
        ram.putWord(fixture.base + 6 * 4, usage_handler | 1);
        ram.putWord(memmap.scb.shcsr, usgfaultena);
        ram.putHalf(fixture.code, c.hw[0]);
        ram.putHalf(fixture.code + 2, c.hw[1]);
        var cpu = try fixture.boot(&ram);
        cpu.profile = c.profile;
        cpu.fp.cpacr = 0x00F0_0000;
        try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
        try std.testing.expectEqual(usage_handler, cpu.regs.pc);
        try std.testing.expectEqual(undefinstr_bit, ram.word(memmap.scb.cfsr));
    }
}
