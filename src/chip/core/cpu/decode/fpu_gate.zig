//! Per-core FPU precision gate for instruction decoding.
//!
//! Keeps `ops/table.zig` group membership untouched while filtering out scalar
//! double-precision, scalar half-precision (`FEAT_FP16`), or all floating-point
//! encodings on cores whose `Profile.fpu` does not implement them. Rejected
//! encodings fall through `decode.decodeFor` as null and take UsageFault
//! UNDEFINSTR via `decode.refused`.
const std = @import("std");

const Instr = @import("../instr.zig").Instr;
const profile = @import("../profile.zig");

const coproc_half: u4 = 0b1001;
const coproc_single: u4 = 0b1010;
const coproc_double: u4 = 0b1011;

pub fn allows(core: profile.Profile, group_name: []const u8, instr: Instr) bool {
    return switch (core.fpu) {
        .double => true,
        .none => allowsNoFpu(core.mve, group_name, instr),
        .single => allowsSingleFpu(core.mve, group_name, instr),
    };
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
    if (isScalarDpGroup(name) or std.mem.eql(u8, name, "fp_convert") or isMveFloatGroup(name)) return false;
    if (std.mem.eql(u8, name, "fp_system")) return mve and instr.hw2 & 0x0FFF == 0x0A10;
    if (!isContextOrTransferGroup(name)) return true;
    if (!mve) return false;
    if (std.mem.eql(u8, name, "fp_move")) return !isHalfMove(instr);
    if (std.mem.eql(u8, name, "fp_mem")) return !isHalfMem(instr);
    return true;
}

fn allowsSingleFpu(mve: bool, name: []const u8, instr: Instr) bool {
    const cp = coproc(instr);
    if (isScalarDpGroup(name)) return cp == coproc_single or (mve and cp == coproc_half);
    if (std.mem.eql(u8, name, "fp_convert")) return cp == coproc_single and (instr.hw1 & 0xF) != 0b0111;
    if (std.mem.eql(u8, name, "fp_system")) return allowsSingleSystem(mve, instr, cp);
    if (std.mem.eql(u8, name, "fp_move")) return mve or !isHalfMove(instr);
    if (std.mem.eql(u8, name, "fp_mem")) return mve or !isHalfMem(instr);
    return true;
}

fn allowsSingleSystem(mve: bool, instr: Instr, cp: u4) bool {
    if (instr.hw2 & 0x0FFF == 0x0A10) return true;
    if (cp == coproc_double) return false;
    return mve or cp != coproc_half;
}
