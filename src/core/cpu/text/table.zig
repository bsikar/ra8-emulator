//! The printer table: which decode group each printer covers, by the group's
//! name in src/core/cpu/ops/table.zig. A group with no entry here has no text
//! yet, and `disasm.one` returns null for it.
const Instr = @import("../instr.zig").Instr;
const Text = @import("text.zig").Text;
const std = @import("std");

pub const Print = *const fn (instr: Instr, out: *Text) void;

pub const Entry = struct {
    group: []const u8,
    print: Print,
};

pub const entries = [_]Entry{
    .{ .group = "shift_imm", .print = @import("shift_imm.zig").print },
    .{ .group = "add_sub", .print = @import("add_sub.zig").print },
    .{ .group = "dp_reg", .print = @import("dp_reg.zig").print },
    .{ .group = "special_data", .print = @import("special_data.zig").print },
    .{ .group = "extend", .print = @import("extend.zig").print },
    .{ .group = "reverse", .print = @import("reverse.zig").print },
    .{ .group = "ldst_imm", .print = @import("ldst_imm.zig").print },
    .{ .group = "ldst_reg", .print = @import("ldst_reg.zig").print },
    .{ .group = "sp_arith", .print = @import("sp_arith.zig").print },
    .{ .group = "ldr_literal", .print = @import("ldr_literal.zig").print },
    .{ .group = "ldm_stm", .print = @import("ldm_stm.zig").print },
    .{ .group = "push_pop", .print = @import("push_pop.zig").print },
    .{ .group = "cbz", .print = @import("cbz.zig").print },
    .{ .group = "branch", .print = @import("branch.zig").print },
    .{ .group = "svc", .print = @import("svc.zig").print },
    .{ .group = "it", .print = @import("it.zig").print },
    .{ .group = "hint", .print = @import("hint.zig").print },
    .{ .group = "blxns", .print = @import("blxns.zig").print },
    .{ .group = "cps", .print = @import("cps.zig").print },
    .{ .group = "imm_arith", .print = @import("imm_arith.zig").print },
    .{ .group = "imm_logic", .print = @import("imm_logic.zig").print },
    .{ .group = "mov_wide", .print = @import("mov_wide.zig").print },
    .{ .group = "add_sub_wide", .print = @import("add_sub_wide.zig").print },
    .{ .group = "dp_shifted", .print = @import("dp_shifted.zig").print },
    .{ .group = "shift_reg", .print = @import("shift_reg.zig").print },
    .{ .group = "bitfield", .print = @import("bitfield.zig").print },
    .{ .group = "saturate", .print = @import("saturate.zig").print },
    .{ .group = "sat16", .print = @import("sat16.zig").print },
    .{ .group = "extend_wide", .print = @import("extend_wide.zig").print },
    .{ .group = "extend_b16", .print = @import("extend_b16.zig").print },
    .{ .group = "divide", .print = @import("divide.zig").print },
    .{ .group = "mul_acc", .print = @import("mul_acc.zig").print },
    .{ .group = "long_mul", .print = @import("long_mul.zig").print },
    .{ .group = "dsp_mul16", .print = @import("dsp_mul16.zig").print },
    .{ .group = "dsp_mulhi", .print = @import("dsp_mulhi.zig").print },
    .{ .group = "dsp_long_mul", .print = @import("dsp_long_mul.zig").print },
    .{ .group = "sat_arith", .print = @import("sat_arith.zig").print },
    .{ .group = "barrier", .print = @import("barrier.zig").print },
    .{ .group = "preload", .print = @import("preload.zig").print },
    .{ .group = "ldst_wide", .print = @import("ldst_wide.zig").print },
    .{ .group = "ldst_reg_wide", .print = @import("ldst_reg_wide.zig").print },
    .{ .group = "ldr_literal_wide", .print = @import("ldr_literal_wide.zig").print },
    .{ .group = "ldrd_strd", .print = @import("ldrd_strd.zig").print },
    .{ .group = "ldm_stm_wide", .print = @import("ldm_stm_wide.zig").print },
    .{ .group = "exclusive", .print = @import("exclusive.zig").print },
    .{ .group = "acq_rel", .print = @import("acq_rel.zig").print },
    .{ .group = "table_branch", .print = @import("table_branch.zig").print },
    .{ .group = "branch_wide", .print = @import("branch_wide.zig").print },
    .{ .group = "mrs_msr", .print = @import("mrs_msr.zig").print },
    .{ .group = "misc_wide", .print = @import("misc_wide.zig").print },
};

pub fn find(group: []const u8) ?Print {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.group, group)) return entry.print;
    }
    return null;
}
