//! Top-level instruction transfer evaluator and 16-bit Thumb ALU/branch ops (RA8EMU-1354).
const std = @import("std");

const add_sub = @import("ra8_chip").core.cpu.ops.add.sub;
const cbz = @import("ra8_chip").core.cpu.ops.cbz;
const decode = @import("ra8_chip").core.cpu.decode;
const dp_reg = @import("ra8_chip").core.cpu.ops.dp.reg;
const effects_mem = @import("effects_mem.zig");
const et = @import("effect_types.zig");
const extend = @import("ra8_chip").core.cpu.ops.extend;
const Instr = @import("ra8_chip").core.cpu.instr.Instr;
const reverse = @import("ra8_chip").core.cpu.ops.reverse;
const shift = @import("ra8_chip").core.cpu.shift;
const sp_arith = @import("ra8_chip").core.cpu.ops.sp_arith;
const value = @import("value.zig");
const wide = @import("effects_wide.zig");

pub const Effect = et.Effect;
pub const FlagUpdate = et.FlagUpdate;
pub const MemAccess = et.MemAccess;
pub const State = et.State;

/// Evaluate one decoded instruction (16-bit or 32-bit) against `state`.
pub fn evaluate(state: *const et.State, instr: Instr, hit: decode.Hit) et.Effect {
    var eff = if (instr.size == 4)
        wide.evaluate(state, instr, hit) orelse et.fallbackFromDisasm(instr)
    else
        evaluateNarrow(state, instr, hit) orelse et.fallbackFromDisasm(instr);

    const is_it = std.mem.eql(u8, hit.group, "it");
    if (state.in_it and !is_it and eff.consumes_cond == null) {
        if (state.it_cond) |c| {
            if (c < 14) eff.consumes_cond = c;
        }
    }
    return eff;
}

fn evaluateNarrow(state: *const et.State, instr: Instr, hit: decode.Hit) ?et.Effect {
    if (effects_mem.evaluateNarrow(state, instr, hit.group)) |mem_eff| return mem_eff;
    const g = hit.group;
    if (std.mem.eql(u8, g, "add_sub")) return evalAddSub(state, instr);
    if (std.mem.eql(u8, g, "shift_imm")) return evalShiftImm(state, instr);
    if (std.mem.eql(u8, g, "dp_reg")) return evalDpReg(state, instr);
    if (std.mem.eql(u8, g, "special_data")) return evalSpecialData(state, instr);
    if (std.mem.eql(u8, g, "sp_arith")) return evalSpArith(state, instr);
    if (std.mem.eql(u8, g, "extend")) return evalExtend(state, instr);
    if (std.mem.eql(u8, g, "reverse")) return evalReverse(state, instr);
    if (std.mem.eql(u8, g, "cbz")) return evalCbz(instr);
    if (std.mem.eql(u8, g, "branch")) return evalBranchNarrow(instr);
    if (isNoGprNarrowGroup(g)) return .{};
    return null;
}

fn isNoGprNarrowGroup(g: []const u8) bool {
    return std.mem.eql(u8, g, "it") or std.mem.eql(u8, g, "hint") or
        std.mem.eql(u8, g, "svc") or std.mem.eql(u8, g, "bkpt") or
        std.mem.eql(u8, g, "udf") or std.mem.eql(u8, g, "cps");
}

fn evalAddSub(state: *const et.State, instr: Instr) et.Effect {
    const hw1 = instr.hw1;
    const e = add_sub.encodings;
    switch (hw1 & e.three_mask) {
        e.add_reg, e.sub_reg, e.add_imm3, e.sub_imm3 => return evalAddSubThree(state, hw1),
        else => {},
    }
    const rd: u4 = @intCast((hw1 >> 8) & 7);
    const imm8: u32 = hw1 & 0xFF;
    const kind = hw1 & e.imm8_mask;
    if (kind == e.cmp_imm8) {
        return .{
            .uses_mask = et.regBit(rd),
            .writes_flags = .{
                .kind = .cmp,
                .lhs_reg = rd,
                .rhs_imm = imm8,
                .lhs_val = state.readReg(rd, instr.address),
                .rhs_val = .{ .constant = imm8 },
            },
        };
    }
    if (kind == e.mov_imm8) {
        const out: value.Value = .{ .constant = imm8 };
        return .{
            .defs_mask = et.regBit(rd),
            .primary_rd = rd,
            .primary_val = out,
            .writes_flags = if (!state.in_it) .{ .kind = .result_flags, .lhs_reg = rd, .lhs_val = out } else null,
        };
    }
    const delta: i32 = if (kind == e.sub_imm8) -@as(i32, @intCast(imm8)) else @intCast(imm8);
    const out = value.evalAdd(state.readReg(rd, instr.address), delta);
    return .{
        .uses_mask = et.regBit(rd),
        .defs_mask = et.regBit(rd),
        .primary_rd = rd,
        .primary_val = out,
        .writes_flags = if (!state.in_it) .{
            .kind = .result_flags,
            .lhs_reg = rd,
            .rhs_imm = imm8,
            .lhs_val = out,
        } else null,
    };
}

fn evalAddSubThree(state: *const et.State, hw1: u16) et.Effect {
    const rd: u4 = @intCast(hw1 & 7);
    const rn: u4 = @intCast((hw1 >> 3) & 7);
    const field: u4 = @intCast((hw1 >> 6) & 7);
    const is_imm = (hw1 & 0x0400) != 0;
    const is_sub = (hw1 & 0x0200) != 0;
    const uses = et.regBit(rn) | if (is_imm) @as(u16, 0) else et.regBit(field);
    const rhs: value.Value = if (is_imm) .{ .constant = field } else state.regs[field];
    const out: value.Value = if (rhs.asConstant()) |y| evalU32AddSub(state.regs[rn], y, is_sub) else .unknown;
    return .{
        .uses_mask = uses,
        .defs_mask = et.regBit(rd),
        .primary_rd = rd,
        .primary_val = out,
        .writes_flags = if (!state.in_it) .{ .kind = .result_flags, .lhs_reg = rd, .lhs_val = out } else null,
    };
}

fn evalU32AddSub(lhs: value.Value, y: u32, is_sub: bool) value.Value {
    if (lhs.asConstant()) |x| {
        return .{ .constant = if (is_sub) x -% y else x +% y };
    }
    if (lhs == .sp_offset) {
        const sy: i32 = @bitCast(y);
        if (!is_sub) return value.evalAdd(lhs, sy);
        if (sy != std.math.minInt(i32)) return value.evalAdd(lhs, -sy);
    }
    return .unknown;
}

fn evalShiftImm(state: *const et.State, instr: Instr) et.Effect {
    const hw1 = instr.hw1;
    const kind: shift.Kind = @fromBackingInt(@intCast((hw1 >> 11) & 3));
    const imm5: u5 = @intCast((hw1 >> 6) & 0x1F);
    const rm: u4 = @intCast((hw1 >> 3) & 7);
    const rd: u4 = @intCast(hw1 & 7);
    const src = state.readReg(rm, instr.address);
    const out: value.Value = if (kind == .lsl and imm5 == 0)
        src
    else if (src.asConstant()) |mc|
        .{ .constant = shift.shiftC(mc, kind, shift.immAmount(kind, imm5), state.carry_in).result }
    else
        .unknown;
    return .{
        .uses_mask = et.regBit(rm),
        .defs_mask = et.regBit(rd),
        .primary_rd = rd,
        .primary_val = out,
        .writes_flags = if (!state.in_it) .{ .kind = .result_flags, .lhs_reg = rd, .lhs_val = out } else null,
    };
}

fn evalDpReg(state: *const et.State, instr: Instr) et.Effect {
    const hw1 = instr.hw1;
    const opcode: dp_reg.Opcode = @fromBackingInt(@intCast((hw1 >> 6) & 0xF));
    const rdn: u4 = @intCast(hw1 & 7);
    const rm: u4 = @intCast((hw1 >> 3) & 7);
    const lhs = state.readReg(rdn, instr.address);
    const rhs = state.readReg(rm, instr.address);
    if (opcode == .tst or opcode == .cmp or opcode == .cmn) {
        const kind: value.FlagKind = switch (opcode) {
            .tst => .tst,
            .cmn => .cmn,
            else => .cmp,
        };
        return .{
            .uses_mask = et.regBit(rdn) | et.regBit(rm),
            .writes_flags = .{ .kind = kind, .lhs_reg = rdn, .rhs_reg = rm, .lhs_val = lhs, .rhs_val = rhs },
        };
    }
    const uses = et.regBit(rm) | if (opcode == .mvn) @as(u16, 0) else et.regBit(rdn);
    const out: value.Value = if (rhs.asConstant()) |y| blk: {
        if (opcode == .mvn) break :blk .{ .constant = dp_reg.compute(.mvn, 0, y, state.carry_in).result };
        if (lhs.asConstant()) |x| break :blk .{ .constant = dp_reg.compute(opcode, x, y, state.carry_in).result };
        break :blk .unknown;
    } else .unknown;
    return .{
        .uses_mask = uses,
        .defs_mask = et.regBit(rdn),
        .primary_rd = rdn,
        .primary_val = out,
        .writes_flags = if (!state.in_it) .{ .kind = .result_flags, .lhs_reg = rdn, .lhs_val = out } else null,
    };
}

fn regMaskNonPc(r: u4) u16 {
    return if (r != 15) et.regBit(r) else 0;
}

fn evalSpecialData(state: *const et.State, instr: Instr) et.Effect {
    const hw1 = instr.hw1;
    const rm: u4 = @intCast((hw1 >> 3) & 0xF);
    if ((hw1 & 0xFF80) == 0x4780) return .{ .uses_mask = regMaskNonPc(rm), .is_call = true };
    if ((hw1 & 0xFF80) == 0x4700) return .{ .uses_mask = regMaskNonPc(rm) };
    const rdn: u4 = @intCast(((hw1 >> 4) & 8) | (hw1 & 7));
    return switch (hw1 & 0xFF00) {
        0x4500 => .{
            .uses_mask = regMaskNonPc(rdn) | regMaskNonPc(rm),
            .writes_flags = .{
                .kind = .cmp,
                .lhs_reg = rdn,
                .rhs_reg = rm,
                .lhs_val = state.readReg(rdn, instr.address),
                .rhs_val = state.readReg(rm, instr.address),
            },
        },
        0x4600 => .{
            .uses_mask = regMaskNonPc(rm),
            .defs_mask = regMaskNonPc(rdn),
            .primary_rd = if (rdn != 15) rdn else null,
            .primary_val = state.readReg(rm, instr.address),
        },
        else => evalSpecialAdd(state, instr.address, rdn, rm),
    };
}

fn evalSpecialAdd(state: *const et.State, addr: u32, rdn: u4, rm: u4) et.Effect {
    const lhs = state.readReg(rdn, addr);
    const rhs = state.readReg(rm, addr);
    const out: value.Value = if (rhs.asConstant()) |rc|
        evalU32AddSub(lhs, rc, false)
    else if (lhs.asConstant()) |lc|
        evalU32AddSub(rhs, lc, false)
    else
        .unknown;
    return .{
        .uses_mask = regMaskNonPc(rdn) | regMaskNonPc(rm),
        .defs_mask = regMaskNonPc(rdn),
        .primary_rd = if (rdn != 15) rdn else null,
        .primary_val = out,
    };
}

fn evalSpArith(state: *const et.State, instr: Instr) et.Effect {
    const hw1 = instr.hw1;
    const e = sp_arith.encodings;
    if ((hw1 & e.sp_imm7_mask) == e.sp_imm7) {
        const imm = @as(i32, hw1 & 0x7F) << 2;
        const delta: i32 = if ((hw1 & e.sp_imm7_sub) != 0) -imm else imm;
        return .{
            .uses_mask = et.regBit(13),
            .defs_mask = et.regBit(13),
            .primary_rd = 13,
            .primary_val = value.evalAdd(state.regs[13], delta),
        };
    }
    const rd: u4 = @intCast((hw1 >> 8) & 7);
    const imm8: u32 = @as(u32, hw1 & 0xFF) << 2;
    if ((hw1 & e.rd_imm8_mask) == e.add_rd_sp) {
        return .{
            .uses_mask = et.regBit(13),
            .defs_mask = et.regBit(rd),
            .primary_rd = rd,
            .primary_val = value.evalAdd(state.regs[13], @intCast(imm8)),
        };
    }
    const base = (instr.address +% 4) & ~@as(u32, 3);
    return .{ .defs_mask = et.regBit(rd), .primary_rd = rd, .primary_val = .{ .constant = base +% imm8 } };
}

fn evalExtend(state: *const et.State, instr: Instr) et.Effect {
    const kind: extend.Kind = @fromBackingInt(@intCast((instr.hw1 >> 6) & 3));
    const rm: u4 = @intCast((instr.hw1 >> 3) & 7);
    const rd: u4 = @intCast(instr.hw1 & 7);
    const out: value.Value = if (state.regs[rm].asConstant()) |mc|
        .{ .constant = extend.apply(kind, mc) }
    else
        .unknown;
    return .{ .uses_mask = et.regBit(rm), .defs_mask = et.regBit(rd), .primary_rd = rd, .primary_val = out };
}

fn evalReverse(state: *const et.State, instr: Instr) et.Effect {
    const kind: reverse.Kind = @fromBackingInt(@intCast((instr.hw1 >> 6) & 3));
    const rm: u4 = @intCast((instr.hw1 >> 3) & 7);
    const rd: u4 = @intCast(instr.hw1 & 7);
    const out: value.Value = if (state.regs[rm].asConstant()) |mc|
        .{ .constant = reverse.apply(kind, mc) }
    else
        .unknown;
    return .{ .uses_mask = et.regBit(rm), .defs_mask = et.regBit(rd), .primary_rd = rd, .primary_val = out };
}

fn evalCbz(instr: Instr) et.Effect {
    const rn: u4 = @intCast(instr.hw1 & 7);
    const cond: u4 = if ((instr.hw1 & cbz.encodings.nonzero) != 0) 1 else 0;
    return .{ .uses_mask = et.regBit(rn), .consumes_cond = cond, .self_cond_reg = rn };
}

fn evalBranchNarrow(instr: Instr) et.Effect {
    if ((instr.hw1 & 0xF000) == 0xD000) {
        const cond: u4 = @intCast((instr.hw1 >> 8) & 0xF);
        if (cond < 14) return .{ .consumes_cond = cond };
    }
    return .{};
}
