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
