//! Per-core FPU precision gate for instruction decoding.
//!
//! Keeps `ops/table.zig` group membership untouched while filtering out scalar
//! double-precision, scalar half-precision (`FEAT_FP16`), Armv8.1-M system
//! register transfers, or all floating-point encodings on cores whose `Profile`
//! does not implement them. Rejected encodings fall through `decode.decodeFor`
//! as null and take UsageFault UNDEFINSTR via `decode.refused`.
const std = @import("std");

const fp_mem = @import("../ops/fp/mem.zig");
const fp_system = @import("../ops/fp/system.zig");
const Instr = @import("../instr.zig").Instr;
const profile = @import("../profile.zig");

const coproc_half: u4 = 0b1001;
const coproc_single: u4 = 0b1010;
const coproc_double: u4 = 0b1011;

pub fn allows(core: profile.Profile, group_name: []const u8, instr: Instr) bool {
    if (core.fpu == .double and core.fp16 and core.v8_1m and core.hasMveFloat()) return true;
    if (!core.hasMveFloat() and isMveFloatGroup(group_name)) return false;
    if (isSystemTransfer(instr) and std.mem.eql(u8, group_name, "fp_system")) {
        return allowsSystemTransfer(core, instr);
    }
    if (isSystemMem(instr) and std.mem.eql(u8, group_name, "fp_mem")) {
        return allowsSystemMem(core, instr);
    }
    return switch (core.fpu) {
        .double => core.fp16 or !usesScalarHalf(group_name, instr),
        .none => allowsNoFpu(core.mve, group_name, instr),
        .single => allowsSingleFpu(core, group_name, instr),
    };
}

fn isSystemTransfer(instr: Instr) bool {
    return instr.size == 4 and instr.hw2 & 0x0FFF == fp_system.encodings.transfer_hw2;
}

fn allowsSystemTransfer(core: profile.Profile, instr: Instr) bool {
    const has_fp_or_mve = core.fpu != .none or core.mve;
    const enc = fp_system.encodings;
    return switch (instr.hw1) {
        enc.vmrs, enc.vmsr => has_fp_or_mve,
        enc.vmrs_vpr, enc.vmsr_vpr, enc.vmrs_p0, enc.vmsr_p0 => core.v8_1m and core.mve,
        enc.vmrs_nzcvqc,
        enc.vmsr_nzcvqc,
        enc.vmrs_fpcxt_ns,
        enc.vmsr_fpcxt_ns,
        enc.vmrs_fpcxt_s,
        enc.vmsr_fpcxt_s,
        => core.v8_1m and has_fp_or_mve,
        else => has_fp_or_mve,
    };
}

fn isSystemMem(instr: Instr) bool {
    return instr.size == 4 and instr.hw1 & 0xFE00 == 0xEC00 and instr.hw2 & 0x0F80 == 0x0F80;
}

fn allowsSystemMem(core: profile.Profile, instr: Instr) bool {
    if (!core.v8_1m) return false;
    if (core.fpu == .none and !core.mve) return false;
    const b = fp_mem.systemBits(instr);
    const reg: u4 = @as(u4, b.regh) << 3 | b.regl;
    if (reg == 12 or reg == 13) return core.mve;
    return true;
}

fn coproc(instr: Instr) u4 {
    return @intCast((instr.hw2 >> 8) & 0xF);
}

fn isMveFloatGroup(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "mve_float") or std.mem.eql(u8, name, "mve_vcmp_fp");
}

fn isScalarDpGroup(name: []const u8) bool {
    return std.mem.eql(u8, name, "fp_arith") or
        std.mem.eql(u8, name, "fp_unary") or
        std.mem.eql(u8, name, "fp_directed");
}

fn isContextOrTransferGroup(name: []const u8) bool {
    return std.mem.eql(u8, name, "fp_move") or
        std.mem.eql(u8, name, "fp_mem") or
        std.mem.eql(u8, name, "vscclrm") or
        std.mem.eql(u8, name, "vlldm_vlstm") or
        std.mem.eql(u8, name, "vlldm_vlstm_t2");
}

fn isHalfMem(instr: Instr) bool {
    return instr.hw2 & 0x0F80 != 0x0F80 and coproc(instr) == coproc_half;
}

fn isHalfMove(instr: Instr) bool {
    return instr.hw1 & 0xFFE0 == 0xEE00 and coproc(instr) == coproc_half;
}

fn allowsNoFpu(mve: bool, name: []const u8, instr: Instr) bool {
    if (isScalarDpGroup(name) or
        std.mem.eql(u8, name, "fp_convert") or
        std.mem.eql(u8, name, "fp_system") or
        isMveFloatGroup(name)) return false;
    if (!isContextOrTransferGroup(name)) return true;
    if (!mve) return false;
    if (std.mem.eql(u8, name, "fp_move")) return !isHalfMove(instr);
    if (std.mem.eql(u8, name, "fp_mem")) return !isHalfMem(instr);
    return true;
}

fn allowsSingleFpu(core: profile.Profile, name: []const u8, instr: Instr) bool {
    const cp = coproc(instr);
    if (isScalarDpGroup(name)) return cp == coproc_single or (core.fp16 and cp == coproc_half);
    if (std.mem.eql(u8, name, "fp_convert")) return cp == coproc_single and (instr.hw1 & 0xF) != 0b0111;
    if (std.mem.eql(u8, name, "fp_system")) return allowsSingleSystem(core.fp16, cp);
    if (std.mem.eql(u8, name, "fp_move")) return core.fp16 or !isHalfMove(instr);
    if (std.mem.eql(u8, name, "fp_mem")) return core.fp16 or !isHalfMem(instr);
    return true;
}

fn allowsSingleSystem(fp16: bool, cp: u4) bool {
    if (cp == coproc_double) return false;
    return fp16 or cp != coproc_half;
}

fn usesScalarHalf(name: []const u8, instr: Instr) bool {
    if (isScalarDpGroup(name)) return coproc(instr) == coproc_half;
    if (std.mem.eql(u8, name, "fp_move")) return isHalfMove(instr);
    if (std.mem.eql(u8, name, "fp_mem")) return isHalfMem(instr);
    if (std.mem.eql(u8, name, "fp_system")) return coproc(instr) == coproc_half;
    return false;
}
