//! Shared instruction transfer types and disasm fallback for decompiler dataflow (RA8EMU-1354).
const std = @import("std");

const bus = @import("ra8_chip").core.cpu.bus;
const Instr = @import("ra8_chip").core.cpu.instr.Instr;
const text = @import("ra8_chip").core.cpu.text.text;
const text_disasm = @import("ra8_chip").core.cpu.text.disasm;
const value = @import("value.zig");

/// NZCV flag write produced by a single instruction before linking setter index.
pub const FlagUpdate = struct {
    kind: value.FlagKind,
    lhs_reg: ?u4 = null,
    rhs_reg: ?u4 = null,
    rhs_imm: ?u32 = null,
    lhs_val: value.Value = .unknown,
    rhs_val: value.Value = .unknown,
};

/// Memory access descriptor for spill tracking across stack-relative slots.
pub const MemAccess = struct {
    load: bool,
    size: u3,
    signed: bool = false,
    rt: u4,
    base_reg: u4,
    offset: i32,
};

/// Abstract machine view supplied to instruction effect evaluators.
pub const State = struct {
    regs: *const [16]value.Value,
    bus: bus.Bus,
    in_it: bool = false,
    it_cond: ?u4 = null,
    carry_in: bool = false,

    pub fn readReg(self: *const State, r: u4, addr: u32) value.Value {
        if (r == 15) return .{ .constant = addr +% 4 };
        return self.regs[r];
    }
};

/// Dataflow transfer summary of one decoded instruction.
pub const Effect = struct {
    uses_mask: u16 = 0,
    defs_mask: u16 = 0,
    primary_rd: ?u4 = null,
    primary_val: value.Value = .unknown,
    secondary_rd: ?u4 = null,
    secondary_val: value.Value = .unknown,
    wback_reg: ?u4 = null,
    wback_val: value.Value = .unknown,
    pair: ?value.RegPair = null,
    writes_flags: ?FlagUpdate = null,
    consumes_cond: ?u4 = null,
    self_cond_reg: ?u4 = null,
    is_call: bool = false,
    pushed_mask: u16 = 0,
    mem: ?MemAccess = null,
    clears_spills: bool = false,
};

pub fn regBit(r: u4) u16 {
    return @as(u16, 1) << r;
}

/// Conservative GPR def-use scan for remaining FP/MVE/DSP groups via `text_disasm`.
pub fn fallbackFromDisasm(instr: Instr) Effect {
    const dis = text_disasm.one(instr) orelse return .{};
    const line = dis.slice();
    const space = std.mem.indexOfScalar(u8, line, ' ') orelse return .{};
    var operands = std.mem.splitScalar(u8, line[space + 1 ..], ',');
    var first = true;
    var uses: u16 = 0;
    var defs: u16 = 0;
    var primary_rd: ?u4 = null;
    while (operands.next()) |chunk| {
        const mask = gprMask(chunk);
        if (first and mask != 0 and std.mem.indexOfScalar(u8, chunk, '[') == null) {
            defs |= mask;
            if (@popCount(mask) == 1) primary_rd = @intCast(@ctz(mask));
        } else {
            uses |= mask;
        }
        first = false;
    }
    return .{ .uses_mask = uses, .defs_mask = defs, .primary_rd = primary_rd };
}

fn gprMask(chunk: []const u8) u16 {
    var mask: u16 = 0;
    var words = std.mem.tokenizeAny(u8, chunk, " []{}!");
    while (words.next()) |word| {
        for (text.names, 0..) |name, r| {
            if (r == 15) continue;
            if (std.mem.eql(u8, word, name)) {
                mask |= regBit(@intCast(r));
                break;
            }
        }
    }
    return mask;
}
