//! Instruction transfer effects for 32-bit Thumb-2 ALU, bitfield, multiply, and control ops (RA8EMU-1354).
const std = @import("std");

const add_sub_wide = @import("ra8_chip").core.cpu.ops.add.sub.wide;
const bitfield = @import("ra8_chip").core.cpu.ops.bitfield;
const csel = @import("ra8_chip").core.csel;
const decode = @import("ra8_chip").core.cpu.decode;
const divide = @import("ra8_chip").core.cpu.ops.divide;
const dp_shifted = @import("ra8_chip").core.cpu.ops.dp.shifted;
const dsp_long_mul = @import("ra8_chip").core.cpu.ops.dsp.long_mul;
const effects_mem = @import("effects_mem.zig");
const et = @import("effect_types.zig");
const extend = @import("ra8_chip").core.cpu.ops.extend;
const extend_wide = @import("ra8_chip").core.cpu.ops.extend.wide;
const imm_arith = @import("ra8_chip").core.cpu.ops.imm.arith;
const imm_fields = @import("ra8_chip").core.cpu.ops.imm.fields;
const imm_logic = @import("ra8_chip").core.cpu.ops.imm.logic;
const Instr = @import("ra8_chip").core.cpu.instr.Instr;
const long_mul = @import("ra8_chip").core.cpu.ops.long.mul;
const mov_wide = @import("ra8_chip").core.cpu.ops.mov_wide;
const mul_acc = @import("ra8_chip").core.cpu.ops.mul_acc;
const shift = @import("ra8_chip").core.cpu.shift;
const shift_reg = @import("ra8_chip").core.cpu.ops.shift.reg;
const thumb_imm = @import("ra8_chip").core.cpu.thumb_imm;
const value = @import("value.zig");

pub const regBit = et.regBit;

/// Evaluate a 32-bit instruction given its decoder group hit; returns null when unhandled.
pub fn evaluate(state: *const et.State, instr: Instr, hit: decode.Hit) ?et.Effect {
    if (effects_mem.evaluateWide(state, instr, hit.group)) |mem_eff| return mem_eff;
    const g = hit.group;
    if (std.mem.eql(u8, g, "mov_wide")) return evalMovWide(state, instr);
    if (std.mem.eql(u8, g, "add_sub_wide")) return evalAddSubWide(state, instr);
    if (std.mem.eql(u8, g, "imm_arith")) return evalImmArith(state, instr);
    if (std.mem.eql(u8, g, "imm_logic")) return evalImmLogic(state, instr);
    if (std.mem.eql(u8, g, "dp_shifted")) return evalDpShifted(state, instr);
    if (std.mem.eql(u8, g, "shift_reg")) return evalShiftReg(state, instr);
    if (std.mem.eql(u8, g, "bitfield")) return evalBitfield(state, instr);
    if (std.mem.eql(u8, g, "extend_wide")) return evalExtendWide(state, instr);
    return evaluateRemaining(state, instr, g);
}

fn evaluateRemaining(state: *const et.State, instr: Instr, g: []const u8) ?et.Effect {
    if (std.mem.eql(u8, g, "divide")) return evalDivide(state, instr);
    if (std.mem.eql(u8, g, "mul_acc")) return evalMulAcc(state, instr);
    if (std.mem.eql(u8, g, "long_mul")) return evalLongMul(state, instr);
    if (std.mem.eql(u8, g, "dsp_long_mul")) return evalDspLongMul(instr);
    if (std.mem.eql(u8, g, "csel")) return evalCsel(instr);
    if (std.mem.eql(u8, g, "branch_wide")) return evalBranchWide(instr);
    if (std.mem.eql(u8, g, "table_branch")) {
        const rn: u4 = @intCast(instr.hw1 & 0xF);
        const rm: u4 = @intCast(instr.hw2 & 0xF);
        return .{ .uses_mask = (if (rn != 15) regBit(rn) else 0) | regBit(rm) };
    }
    if (std.mem.eql(u8, g, "lob") or std.mem.eql(u8, g, "mve_lob_tp")) return evalLob(instr);
    if (std.mem.eql(u8, g, "mrs_msr")) return evalMrsMsr(instr);
    if (isNoGprWideGroup(g)) return .{};
    return null;
}

fn isNoGprWideGroup(g: []const u8) bool {
    return std.mem.eql(u8, g, "hint") or std.mem.eql(u8, g, "barrier") or
        std.mem.eql(u8, g, "preload") or std.mem.eql(u8, g, "udf") or
        std.mem.eql(u8, g, "sg") or std.mem.eql(u8, g, "pac");
}

fn evalMovWide(state: *const et.State, instr: Instr) et.Effect {
    const rd: u4 = @intCast((instr.hw2 >> 8) & 0xF);
    const imm = mov_wide.imm16(instr);
    if ((instr.hw1 & mov_wide.encodings.mask) == mov_wide.encodings.movw) {
        return .{ .defs_mask = regBit(rd), .primary_rd = rd, .primary_val = .{ .constant = imm } };
    }
    const val: value.Value = if (state.readReg(rd, instr.address).asConstant()) |low|
        .{ .constant = (@as(u32, imm) << 16) | (low & 0xFFFF) }
    else
        .unknown;
    return .{ .uses_mask = regBit(rd), .defs_mask = regBit(rd), .primary_rd = rd, .primary_val = val };
}

fn evalAddSubWide(state: *const et.State, instr: Instr) et.Effect {
    const f = add_sub_wide.Fields.of(instr) orelse return .{};
    const pc_base: u32 = (instr.address +% 4) & ~@as(u32, 3);
    const base_val: value.Value = if (f.rn == 15) .{ .constant = pc_base } else state.readReg(f.rn, instr.address);
    const delta: i32 = if (f.sub) -@as(i32, @intCast(f.imm12)) else @intCast(f.imm12);
    return .{
        .uses_mask = if (f.rn == 15) 0 else regBit(f.rn),
        .defs_mask = regBit(f.rd),
        .primary_rd = f.rd,
        .primary_val = value.evalAdd(base_val, delta),
    };
}

fn evalImmArith(state: *const et.State, instr: Instr) et.Effect {
    const f = imm_fields.Fields.of(instr) orelse return .{};
    const exp = thumb_imm.expandC(thumb_imm.imm12(instr), false) orelse return .{};
    const imm = exp.result;
    const lhs = state.readReg(f.rn, instr.address);
    if (f.rd == 15 and f.s) {
        const kind: value.FlagKind = if (f.opcode == imm_arith.opcodes.sub) .cmp else .cmn;
        return .{
            .uses_mask = regBit(f.rn),
            .writes_flags = .{
                .kind = kind,
                .lhs_reg = f.rn,
                .rhs_imm = imm,
                .lhs_val = lhs,
                .rhs_val = .{ .constant = imm },
            },
        };
    }
    const out = evalImmArithVal(f.opcode, lhs, imm);
    return .{
        .uses_mask = regBit(f.rn),
        .defs_mask = regBit(f.rd),
        .primary_rd = f.rd,
        .primary_val = out,
        .writes_flags = if (f.s) .{
            .kind = .result_flags,
            .lhs_reg = f.rd,
            .rhs_imm = imm,
            .lhs_val = out,
        } else null,
    };
}

fn evalImmArithVal(opcode: u4, lhs: value.Value, imm: u32) value.Value {
    const s_imm: i32 = @bitCast(imm);
    if (lhs == .sp_offset) {
        return switch (opcode) {
            imm_arith.opcodes.add => value.evalAdd(lhs, s_imm),
            imm_arith.opcodes.sub => if (s_imm != std.math.minInt(i32)) value.evalAdd(lhs, -s_imm) else .unknown,
            else => .unknown,
        };
    }
    const c = lhs.asConstant() orelse return .unknown;
    return switch (opcode) {
        imm_arith.opcodes.add => .{ .constant = c +% imm },
        imm_arith.opcodes.sub => .{ .constant = c -% imm },
        imm_arith.opcodes.rsb => .{ .constant = imm -% c },
        else => .unknown,
    };
}

fn evalImmLogic(state: *const et.State, instr: Instr) et.Effect {
    const f = imm_fields.Fields.of(instr) orelse return .{};
    const exp = thumb_imm.expandC(thumb_imm.imm12(instr), state.carry_in) orelse return .{};
    const imm = exp.result;
    const uses: u16 = if (f.rn == 15) 0 else regBit(f.rn);
    const lhs: value.Value = if (f.rn == 15) .{ .constant = 0 } else state.readReg(f.rn, instr.address);
    if (f.rd == 15 and f.s) {
        const kind: value.FlagKind = if (f.opcode == imm_logic.opcodes.and_) .tst else .teq;
        return .{
            .uses_mask = uses,
            .writes_flags = .{
                .kind = kind,
                .lhs_reg = f.rn,
                .rhs_imm = imm,
                .lhs_val = lhs,
                .rhs_val = .{ .constant = imm },
            },
        };
    }
    const out = evalLogicConst(f.opcode, lhs, imm);
    return .{
        .uses_mask = uses,
        .defs_mask = regBit(f.rd),
        .primary_rd = f.rd,
        .primary_val = out,
        .writes_flags = if (f.s) .{ .kind = .result_flags, .lhs_reg = f.rd, .lhs_val = out } else null,
    };
}

fn evalLogicConst(opcode: u4, lhs: value.Value, rhs: u32) value.Value {
    const c = lhs.asConstant() orelse return .unknown;
    const res = switch (opcode) {
        imm_logic.opcodes.and_ => c & rhs,
        imm_logic.opcodes.bic => c & ~rhs,
        imm_logic.opcodes.orr => c | rhs,
        imm_logic.opcodes.orn => c | ~rhs,
        imm_logic.opcodes.eor => c ^ rhs,
        else => return .unknown,
    };
    return .{ .constant = res };
}

fn evalDpShifted(state: *const et.State, instr: Instr) et.Effect {
    const f = dp_shifted.Fields.of(instr) orelse return .{};
    const uses = regBit(f.rm) | if (f.rn == 15) @as(u16, 0) else regBit(f.rn);
    const rn_val: value.Value = if (f.rn == 15) .{ .constant = 0 } else state.readReg(f.rn, instr.address);
    const rm_val = state.readReg(f.rm, instr.address);
    if (f.rd == 15 and f.s) {
        const kind: value.FlagKind = switch (f.opcode) {
            dp_shifted.opcodes.add => .cmn,
            dp_shifted.opcodes.and_ => .tst,
            dp_shifted.opcodes.eor => .teq,
            else => .cmp,
        };
        return .{
            .uses_mask = uses,
            .writes_flags = .{ .kind = kind, .lhs_reg = f.rn, .rhs_reg = f.rm, .lhs_val = rn_val, .rhs_val = rm_val },
        };
    }
    const out = computeDpShifted(f, rn_val, rm_val, state.carry_in);
    return .{
        .uses_mask = uses,
        .defs_mask = regBit(f.rd),
        .primary_rd = f.rd,
        .primary_val = out,
        .writes_flags = if (f.s) .{ .kind = .result_flags, .lhs_reg = f.rd, .lhs_val = out } else null,
    };
}

fn computeDpShifted(f: dp_shifted.Fields, rn_val: value.Value, rm_val: value.Value, carry_in: bool) value.Value {
    if (f.rn == 15 and f.opcode == dp_shifted.opcodes.orr and f.imm5 == 0 and f.kind == .lsl) {
        return rm_val;
    }
    const rm_c = rm_val.asConstant() orelse return .unknown;
    const shifted = shift.immShiftC(rm_c, f.kind, f.imm5, carry_in).result;
    if (f.rn != 15 and rn_val == .sp_offset) {
        const s_off: i32 = @bitCast(shifted);
        if (f.opcode == dp_shifted.opcodes.add) return value.evalAdd(rn_val, s_off);
        if (f.opcode == dp_shifted.opcodes.sub and s_off != std.math.minInt(i32)) {
            return value.evalAdd(rn_val, -s_off);
        }
        return .unknown;
    }
    const rn_c = rn_val.asConstant() orelse return .unknown;
    const out: u32 = switch (f.opcode) {
        dp_shifted.opcodes.and_ => rn_c & shifted,
        dp_shifted.opcodes.bic => rn_c & ~shifted,
        dp_shifted.opcodes.orr => rn_c | shifted,
        dp_shifted.opcodes.orn => rn_c | ~shifted,
        dp_shifted.opcodes.eor => rn_c ^ shifted,
        dp_shifted.opcodes.add => rn_c +% shifted,
        dp_shifted.opcodes.sub => rn_c -% shifted,
        dp_shifted.opcodes.rsb => shifted -% rn_c,
        else => return .unknown,
    };
    return .{ .constant = out };
}

fn evalShiftReg(state: *const et.State, instr: Instr) et.Effect {
    const f = shift_reg.Fields.of(instr) orelse return .{};
    const n_val = state.readReg(f.rn, instr.address);
    const m_val = state.readReg(f.rm, instr.address);
    const out: value.Value = if (n_val.asConstant()) |nc|
        if (m_val.asConstant()) |mc|
            .{ .constant = shift.shiftC(nc, f.kind, mc & 0xFF, state.carry_in).result }
        else
            .unknown
    else
        .unknown;
    return .{
        .uses_mask = regBit(f.rn) | regBit(f.rm),
        .defs_mask = regBit(f.rd),
        .primary_rd = f.rd,
        .primary_val = out,
        .writes_flags = if (f.s) .{ .kind = .result_flags, .lhs_reg = f.rd, .lhs_val = out } else null,
    };
}

fn evalBitfield(state: *const et.State, instr: Instr) et.Effect {
    const f = bitfield.Fields.of(instr) orelse return .{};
    var uses: u16 = if (f.rn == 15) 0 else regBit(f.rn);
    if (f.kind == .bfi) uses |= regBit(f.rd);
    const rn_c: ?u32 = if (f.rn == 15) 0 else state.readReg(f.rn, instr.address).asConstant();
    const rd_c: ?u32 = if (f.kind == .bfi) state.readReg(f.rd, instr.address).asConstant() else 0;
    const out: value.Value = if (rn_c) |nc|
        if (rd_c) |dc| .{ .constant = bitfield.result(f, nc, dc) } else .unknown
    else
        .unknown;
    return .{ .uses_mask = uses, .defs_mask = regBit(f.rd), .primary_rd = f.rd, .primary_val = out };
}

fn evalExtendWide(state: *const et.State, instr: Instr) et.Effect {
    const f = extend_wide.Fields.of(instr) orelse return .{};
    const uses = regBit(f.rm) | if (f.rn == 15) @as(u16, 0) else regBit(f.rn);
    const rm_c = state.readReg(f.rm, instr.address).asConstant() orelse {
        return .{ .uses_mask = uses, .defs_mask = regBit(f.rd), .primary_rd = f.rd };
    };
    const res = if (f.rn == 15)
        extend.apply(f.kind, std.math.rotr(u32, rm_c, f.rotation))
    else if (state.readReg(f.rn, instr.address).asConstant()) |rn_c|
        extend_wide.result(f, rm_c, rn_c)
    else
        return .{ .uses_mask = uses, .defs_mask = regBit(f.rd), .primary_rd = f.rd };
    return .{ .uses_mask = uses, .defs_mask = regBit(f.rd), .primary_rd = f.rd, .primary_val = .{ .constant = res } };
}

fn evalDivide(state: *const et.State, instr: Instr) et.Effect {
    const f = divide.fields(instr);
    const is_sdiv = (instr.hw1 & divide.encodings.hw1_mask) == divide.encodings.sdiv;
    const nc = state.readReg(f.rn, instr.address).asConstant();
    const mc = state.readReg(f.rm, instr.address).asConstant();
    const val: value.Value = if (nc) |a| if (mc) |b| .{
        .constant = if (is_sdiv) divide.signedQuotient(a, b) else divide.unsignedQuotient(a, b),
    } else .unknown else .unknown;
    return .{
        .uses_mask = regBit(f.rn) | regBit(f.rm),
        .defs_mask = regBit(f.rd),
        .primary_rd = f.rd,
        .primary_val = val,
    };
}

fn evalMulAcc(state: *const et.State, instr: Instr) et.Effect {
    const f = mul_acc.Fields.of(instr) orelse return .{};
    const uses = regBit(f.rn) | regBit(f.rm) | if (f.kind == .mul) @as(u16, 0) else regBit(f.ra);
    const nc = state.readReg(f.rn, instr.address).asConstant();
    const mc = state.readReg(f.rm, instr.address).asConstant();
    const val: value.Value = if (nc) |n| if (mc) |m| blk: {
        if (f.kind == .mul) break :blk .{ .constant = mul_acc.result(.mul, n, m, 0) };
        if (state.readReg(f.ra, instr.address).asConstant()) |a| {
            break :blk .{ .constant = mul_acc.result(f.kind, n, m, a) };
        }
        break :blk .unknown;
    } else .unknown else .unknown;
    return .{ .uses_mask = uses, .defs_mask = regBit(f.rd), .primary_rd = f.rd, .primary_val = val };
}

fn pairEffect(uses: u16, pair: value.RegPair) et.Effect {
    return .{
        .uses_mask = uses,
        .defs_mask = regBit(pair.lo_reg) | regBit(pair.hi_reg),
        .primary_rd = pair.lo_reg,
        .primary_val = .{ .pair_lo = pair },
        .secondary_rd = pair.hi_reg,
        .secondary_val = .{ .pair_hi = pair },
        .pair = pair,
    };
}

fn evalLongMul(state: *const et.State, instr: Instr) et.Effect {
    const f = long_mul.Fields.of(instr) orelse return .{};
    var uses = regBit(f.rn) | regBit(f.rm);
    if (f.accumulate) uses |= regBit(f.rd_lo) | regBit(f.rd_hi);
    var const_u64: ?u64 = null;
    if (!f.accumulate) {
        if (state.readReg(f.rn, instr.address).asConstant()) |a| {
            if (state.readReg(f.rm, instr.address).asConstant()) |b| const_u64 = long_mul.product(a, b, f.signed);
        }
    }
    return pairEffect(uses, .{
        .lo_reg = f.rd_lo,
        .hi_reg = f.rd_hi,
        .def_address = instr.address,
        .kind = .long_mul,
        .const_u64 = const_u64,
    });
}

fn evalDspLongMul(instr: Instr) et.Effect {
    const f = dsp_long_mul.Fields.of(instr) orelse return .{};
    const uses = regBit(f.rn) | regBit(f.rm) | regBit(f.rd_lo) | regBit(f.rd_hi);
    return pairEffect(uses, .{ .lo_reg = f.rd_lo, .hi_reg = f.rd_hi, .def_address = instr.address, .kind = .long_mul });
}

fn evalCsel(instr: Instr) et.Effect {
    const f = csel.decode(instr.hw1, instr.hw2) orelse return .{};
    var uses: u16 = 0;
    if (f.then_source != csel.encoding.zero_register) uses |= regBit(f.then_source);
    if (f.else_source != csel.encoding.zero_register) uses |= regBit(f.else_source);
    return .{
        .uses_mask = uses,
        .defs_mask = regBit(f.destination),
        .primary_rd = f.destination,
        .consumes_cond = f.condition,
    };
}

fn evalBranchWide(instr: Instr) et.Effect {
    if ((instr.hw2 & 0xD000) == 0xD000) return .{ .is_call = true };
    if ((instr.hw2 & 0xD000) == 0x8000 and ((instr.hw1 >> 6) & 0xE) != 0xE) {
        return .{ .consumes_cond = @intCast((instr.hw1 >> 6) & 0xF) };
    }
    return .{};
}

fn evalLob(instr: Instr) et.Effect {
    if (instr.hw1 == 0xF00F or instr.hw1 == 0xF01F) {
        return .{ .uses_mask = regBit(14), .defs_mask = regBit(14) };
    }
    const rn: u4 = @intCast(instr.hw1 & 0xF);
    const uses: u16 = if (rn != 13 and rn != 15) regBit(rn) else 0;
    return .{ .uses_mask = uses, .defs_mask = regBit(14) };
}

fn evalMrsMsr(instr: Instr) et.Effect {
    if ((instr.hw1 & 0xFFE0) == 0xF3E0) {
        const rd: u4 = @intCast((instr.hw2 >> 8) & 0xF);
        if (rd != 13 and rd != 15) return .{ .defs_mask = regBit(rd), .primary_rd = rd };
        return .{};
    }
    const rn: u4 = @intCast(instr.hw1 & 0xF);
    if (rn != 13 and rn != 15) return .{ .uses_mask = regBit(rn) };
    return .{};
}
