//! Memory, stack, literal, and load/store-multiple instruction transfer effects (RA8EMU-1354).
const std = @import("std");

const et = @import("effect_types.zig");
const Instr = @import("ra8_chip").core.cpu.instr.Instr;
const ldm_stm = @import("ra8_chip").core.cpu.ops.ldm.stm;
const ldm_stm_wide = @import("ra8_chip").core.cpu.ops.ldm.stm.wide;
const ldr_literal = @import("ra8_chip").core.cpu.ops.ldr.literal;
const ldr_literal_wide = @import("ra8_chip").core.cpu.ops.ldr.literal.wide;
const ldrd_strd = @import("ra8_chip").core.cpu.ops.ldrd_strd;
const ldst_imm = @import("ra8_chip").core.cpu.ops.ldst.imm;
const ldst_reg = @import("ra8_chip").core.cpu.ops.ldst.reg;
const ldst_reg_wide = @import("ra8_chip").core.cpu.ops.ldst.reg.wide;
const ldst_wide = @import("ra8_chip").core.cpu.ops.ldst.wide;
const push_pop = @import("ra8_chip").core.cpu.ops.push_pop;
const value = @import("value.zig");

const regBit = et.regBit;

/// Evaluate a 16-bit memory/stack instruction group, or null when not a narrow memory group.
pub fn evaluateNarrow(state: *const et.State, instr: Instr, group: []const u8) ?et.Effect {
    if (std.mem.eql(u8, group, "ldr_literal")) return evalLdrLiteral(state, instr);
    if (std.mem.eql(u8, group, "ldst_imm")) return evalLdstImm(state, instr);
    if (std.mem.eql(u8, group, "ldst_reg")) return evalLdstReg(instr);
    if (std.mem.eql(u8, group, "push_pop")) return evalPushPop(state, instr);
    if (std.mem.eql(u8, group, "ldm_stm")) return evalLdmStm(state, instr);
    return null;
}

/// Evaluate a 32-bit memory/stack instruction group, or null when not a wide memory group.
pub fn evaluateWide(state: *const et.State, instr: Instr, group: []const u8) ?et.Effect {
    if (std.mem.eql(u8, group, "ldr_literal_wide")) return evalLdrLiteralWide(state, instr);
    if (std.mem.eql(u8, group, "ldst_wide")) return evalLdstWide(state, instr);
    if (std.mem.eql(u8, group, "ldst_reg_wide")) return evalLdstRegWide(instr);
    if (std.mem.eql(u8, group, "ldrd_strd")) return evalLdrdStrd(state, instr);
    if (std.mem.eql(u8, group, "ldm_stm_wide")) return evalLdmStmWide(state, instr);
    return null;
}

fn evalLdrLiteral(state: *const et.State, instr: Instr) et.Effect {
    const rt: u4 = @intCast((instr.hw1 >> 8) & 7);
    const pool = ldr_literal.address(instr);
    var bytes: [4]u8 = undefined;
    const val: value.Value = if (state.bus.peek(pool, &bytes))
        .{ .constant = std.mem.readInt(u32, &bytes, .little) }
    else
        .unknown;
    return .{ .defs_mask = regBit(rt), .primary_rd = rt, .primary_val = val };
}

fn evalLdstImm(state: *const et.State, instr: Instr) et.Effect {
    const hw1 = instr.hw1;
    const e = ldst_imm.encodings;
    const kind = hw1 & e.mask;
    const is_load = (kind & 0x0800) != 0;
    const is_sp = (kind & ~@as(u16, 0x0800)) == e.str_sp;
    const rt: u4 = if (is_sp) @intCast((hw1 >> 8) & 7) else @intCast(hw1 & 7);
    const rn: u4 = if (is_sp) 13 else @intCast((hw1 >> 3) & 7);
    const size: u3 = if (is_sp) 4 else switch (kind & ~@as(u16, 0x0800)) {
        e.str_imm5 => 4,
        e.strb_imm5 => 1,
        else => 2,
    };
    const off: i32 = if (is_sp) @intCast(@as(u32, hw1 & 0xFF) << 2) else @intCast(((hw1 >> 6) & 0x1F) * size);
    const mem: et.MemAccess = .{ .load = is_load, .size = size, .rt = rt, .base_reg = rn, .offset = off };
    if (is_load) {
        return .{ .uses_mask = regBit(rn), .defs_mask = regBit(rt), .primary_rd = rt, .mem = mem };
    }
    return .{
        .uses_mask = regBit(rn) | regBit(rt),
        .mem = mem,
        .clears_spills = state.readReg(rn, instr.address) != .sp_offset,
    };
}

fn evalLdstReg(instr: Instr) et.Effect {
    const hw1 = instr.hw1;
    const kind = hw1 & ldst_reg.encodings.mask;
    const is_load = kind >= ldst_reg.encodings.ldrsb;
    const rn: u4 = @intCast((hw1 >> 3) & 7);
    const rm: u4 = @intCast((hw1 >> 6) & 7);
    const rt: u4 = @intCast(hw1 & 7);
    if (is_load) {
        return .{ .uses_mask = regBit(rn) | regBit(rm), .defs_mask = regBit(rt), .primary_rd = rt };
    }
    return .{ .uses_mask = regBit(rn) | regBit(rm) | regBit(rt), .clears_spills = true };
}

fn evalPushPop(state: *const et.State, instr: Instr) et.Effect {
    const hw1 = instr.hw1;
    const reg_list = push_pop.list(hw1);
    const count: i32 = @intCast(@as(u32, @popCount(reg_list)) * 4);
    if ((hw1 & push_pop.encodings.mask) == push_pop.encodings.push_t1) {
        return .{
            .uses_mask = regBit(13) | reg_list,
            .defs_mask = regBit(13),
            .primary_rd = 13,
            .primary_val = value.evalAdd(state.regs[13], -count),
            .pushed_mask = reg_list,
        };
    }
    return .{
        .uses_mask = regBit(13),
        .defs_mask = regBit(13) | (reg_list & ~regBit(15)),
        .primary_rd = 13,
        .primary_val = value.evalAdd(state.regs[13], count),
    };
}

fn evalLdmStm(state: *const et.State, instr: Instr) et.Effect {
    const hw1 = instr.hw1;
    const rn = ldm_stm.base(hw1);
    const reg_list: u16 = hw1 & 0xFF;
    const byte_len: i32 = @intCast(@as(u32, @popCount(reg_list)) * 4);
    const wback_val = value.evalAdd(state.regs[rn], byte_len);
    if ((hw1 & ldm_stm.encodings.mask) == ldm_stm.encodings.ldm_t1) {
        const wback = (reg_list & regBit(rn)) == 0;
        return .{
            .uses_mask = regBit(rn),
            .defs_mask = reg_list | if (wback) regBit(rn) else @as(u16, 0),
            .wback_reg = if (wback) rn else null,
            .wback_val = wback_val,
        };
    }
    return .{
        .uses_mask = regBit(rn) | reg_list,
        .defs_mask = regBit(rn),
        .wback_reg = rn,
        .wback_val = wback_val,
        .clears_spills = state.regs[rn] != .sp_offset,
    };
}

fn evalLdrLiteralWide(state: *const et.State, instr: Instr) et.Effect {
    const f = ldr_literal_wide.form(instr) orelse return .{};
    if (f.rt == 15) return .{};
    var bytes = @as([4]u8, @splat(0));
    const val: value.Value = if (state.bus.peek(f.address, bytes[0..f.size])) blk: {
        var raw = std.mem.readInt(u32, &bytes, .little);
        if (f.signed) {
            const top: u5 = @intCast(@as(u6, f.size) * 8 - 1);
            if ((raw >> top) & 1 != 0) raw |= ~@as(u32, 0) << top;
        }
        break :blk .{ .constant = raw };
    } else .unknown;
    return .{ .defs_mask = regBit(f.rt), .primary_rd = f.rt, .primary_val = val };
}

fn evalLdstWide(state: *const et.State, instr: Instr) et.Effect {
    const f = ldst_wide.form(instr) orelse return .{};
    var uses = regBit(f.rn);
    var defs: u16 = 0;
    const base_val = state.readReg(f.rn, instr.address);
    const signed_off: i32 = if (f.add) @intCast(f.offset) else -@as(i32, @intCast(f.offset));
    if (!f.load) {
        uses |= regBit(f.rt);
    } else if (f.rt != 15) {
        defs |= regBit(f.rt);
    }
    var wback_reg: ?u4 = null;
    var wback_val: value.Value = .unknown;
    if (f.writeback) {
        defs |= regBit(f.rn);
        wback_reg = f.rn;
        wback_val = value.evalAdd(base_val, signed_off);
    }
    return .{
        .uses_mask = uses,
        .defs_mask = defs,
        .primary_rd = if (f.load and f.rt != 15) f.rt else null,
        .wback_reg = wback_reg,
        .wback_val = wback_val,
        .mem = if (f.rt != 15) .{
            .load = f.load,
            .size = f.size,
            .signed = f.signed,
            .rt = f.rt,
            .base_reg = f.rn,
            .offset = if (f.index) signed_off else 0,
        } else null,
        .clears_spills = !f.load and base_val != .sp_offset,
    };
}

fn evalLdstRegWide(instr: Instr) et.Effect {
    const f = ldst_reg_wide.Fields.of(instr) orelse return .{};
    if (f.load) {
        return .{
            .uses_mask = regBit(f.rn) | regBit(f.rm),
            .defs_mask = if (f.rt != 15) regBit(f.rt) else 0,
            .primary_rd = if (f.rt != 15) f.rt else null,
        };
    }
    return .{
        .uses_mask = regBit(f.rn) | regBit(f.rm) | regBit(f.rt),
        .clears_spills = true,
    };
}

fn evalLdrdStrd(state: *const et.State, instr: Instr) et.Effect {
    const f = ldrd_strd.Form.of(instr) orelse return .{};
    const base_val = state.readReg(f.rn, instr.address);
    const delta: i32 = if (f.add) @intCast(f.offset) else -@as(i32, @intCast(f.offset));
    var defs: u16 = if (f.wback) regBit(f.rn) else 0;
    const wback_reg: ?u4 = if (f.wback) f.rn else null;
    const wback_val: value.Value = if (f.wback) value.evalAdd(base_val, delta) else .unknown;
    if (!f.load) {
        return .{
            .uses_mask = regBit(f.rn) | regBit(f.rt) | regBit(f.rt2),
            .defs_mask = defs,
            .wback_reg = wback_reg,
            .wback_val = wback_val,
            .clears_spills = true,
        };
    }
    const pair: value.RegPair = .{ .lo_reg = f.rt, .hi_reg = f.rt2, .def_address = instr.address, .kind = .ldrd };
    defs |= regBit(f.rt) | regBit(f.rt2);
    return .{
        .uses_mask = regBit(f.rn),
        .defs_mask = defs,
        .primary_rd = f.rt,
        .primary_val = .{ .pair_lo = pair },
        .secondary_rd = f.rt2,
        .secondary_val = .{ .pair_hi = pair },
        .wback_reg = wback_reg,
        .wback_val = wback_val,
        .pair = pair,
    };
}

fn evalLdmStmWide(state: *const et.State, instr: Instr) et.Effect {
    const f = ldm_stm_wide.Form.of(instr) orelse return .{};
    const byte_len: i32 = @intCast(@as(u32, @popCount(f.list)) * 4);
    const delta: i32 = if (f.before) -byte_len else byte_len;
    const wback_reg: ?u4 = if (f.wback) f.rn else null;
    const wback_val = if (f.wback) value.evalAdd(state.readReg(f.rn, instr.address), delta) else .unknown;
    if (f.load) {
        const defs = (f.list & ~regBit(15)) | if (f.wback) regBit(f.rn) else @as(u16, 0);
        return .{
            .uses_mask = regBit(f.rn),
            .defs_mask = defs,
            .wback_reg = wback_reg,
            .wback_val = wback_val,
        };
    }
    const push_sp = f.rn == 13 and f.before and f.wback;
    return .{
        .uses_mask = regBit(f.rn) | f.list,
        .defs_mask = if (f.wback) regBit(f.rn) else 0,
        .wback_reg = wback_reg,
        .wback_val = wback_val,
        .pushed_mask = if (push_sp) f.list else 0,
        .clears_spills = !push_sp and state.readReg(f.rn, instr.address) != .sp_offset,
    };
}
