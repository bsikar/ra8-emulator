//! The printer table: which decode group each printer covers, by the group's
//! name in src/core/cpu/ops/table.zig. A group with no entry here has no text
//! yet, and disasm.one returns null for it.
const Instr = @import("../instr.zig").Instr;
const Text = @import("text.zig").Text;
const std = @import("std");

pub const Print = *const fn (instr: Instr, out: *Text) void;
pub const PredicatedPrint = *const fn (instr: Instr, out: *Text, suffix: []const u8) void;

pub const Entry = struct {
    group: []const u8,
    print: Print,
    predicated: ?PredicatedPrint = null,
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
    .{ .group = "sg", .print = @import("sg.zig").print },
    .{ .group = "tt", .print = @import("tt.zig").print },
    .{ .group = "udf", .print = @import("udf.zig").print },
    .{ .group = "bkpt", .print = @import("bkpt.zig").print },
    .{ .group = "bxns", .print = @import("bxns.zig").print },
    .{ .group = "sel", .print = @import("sel.zig").print },
    .{ .group = "pkh", .print = @import("pkh.zig").print },
    .{ .group = "umaal", .print = @import("umaal.zig").print },
    .{ .group = "usad8", .print = @import("usad8.zig").print },
    .{ .group = "parallel", .print = @import("parallel.zig").print },
    .{ .group = "dsp_dual", .print = @import("dsp_dual.zig").print },
    .{ .group = "csel", .print = @import("csel.zig").print },
    .{ .group = "clrm", .print = @import("clrm.zig").print },
    .{ .group = "vscclrm", .print = @import("vscclrm.zig").print },
    .{ .group = "long_shift", .print = @import("long_shift.zig").print },
    .{ .group = "long_shift_reg", .print = @import("long_shift_reg.zig").print },
    .{ .group = "long_shift_sat", .print = @import("long_shift_sat.zig").print },
    .{ .group = "long_shift_sat64", .print = @import("long_shift_sat64.zig").print },
    .{ .group = "lob", .print = @import("lob.zig").print },
    .{ .group = "mve_lob_tp", .print = @import("mve_lob_tp.zig").print },
    .{ .group = "mve_vpred", .print = @import("mve_vpred.zig").print, .predicated = @import("mve_vpred.zig").printPredicated },
    .{ .group = "mve_vctp", .print = @import("mve_vctp.zig").print },
    .{ .group = "mve_vdup", .print = @import("mve_vdup.zig").print, .predicated = @import("mve_vdup.zig").printPredicated },
    .{ .group = "mve_lane_pair", .print = @import("mve_lane_pair.zig").print },
    .{ .group = "mve_lane_move", .print = @import("mve_lane_move.zig").print },
    .{ .group = "mve_vmaxv", .print = @import("mve_vmaxv.zig").print, .predicated = @import("mve_vmaxv.zig").printPredicated },
    .{ .group = "mve_int_pair", .print = @import("mve_int_pair.zig").print, .predicated = @import("mve_int_pair.zig").printPredicated },
    .{ .group = "mve_float", .print = @import("mve_float.zig").print, .predicated = @import("mve_float.zig").printPredicated },
    .{ .group = "mve_int_mulh", .print = @import("mve_int_mulh.zig").print, .predicated = @import("mve_int_mulh.zig").printPredicated },
    .{ .group = "mve_int_shift", .print = @import("mve_int_shift.zig").print, .predicated = @import("mve_int_shift.zig").printPredicated },
    .{ .group = "mve_gather", .print = @import("mve_gather.zig").print, .predicated = @import("mve_gather.zig").printPredicated },
    .{ .group = "mve_gather64", .print = @import("mve_gather64.zig").print, .predicated = @import("mve_gather64.zig").printPredicated },
    .{ .group = "mve_gather_imm", .print = @import("mve_gather_imm.zig").print, .predicated = @import("mve_gather_imm.zig").printPredicated },
    .{ .group = "mve_vpst", .print = @import("mve_vpst.zig").print },
    .{ .group = "mve_vcmp", .print = @import("mve_vcmp.zig").print, .predicated = @import("mve_vcmp.zig").printPredicated },
    .{ .group = "mve_vcmp_fp", .print = @import("mve_vcmp_fp.zig").print, .predicated = @import("mve_vcmp_fp.zig").printPredicated },
    .{ .group = "mve_int", .print = @import("mve_int.zig").print, .predicated = @import("mve_int.zig").printPredicated },
    .{ .group = "branch_future", .print = @import("branch_future.zig").print },
    .{ .group = "pac", .print = @import("pac.zig").print },
    .{ .group = "vlldm_vlstm", .print = @import("vlldm_vlstm.zig").print },
    .{ .group = "vlldm_vlstm_t2", .print = @import("vlldm_vlstm.zig").print },
    .{ .group = "fp_arith", .print = @import("fp.zig").arith },
    .{ .group = "fp_unary", .print = @import("fp.zig").unary },
    .{ .group = "fp_system", .print = @import("fp.zig").system },
    .{ .group = "fp_convert", .print = @import("fp.zig").convert },
    .{ .group = "fp_directed", .print = @import("fp.zig").directed },
    .{ .group = "fp_move", .print = @import("fp.zig").move },
    .{ .group = "fp_mem", .print = @import("fp.zig").mem },
};

pub fn findEntry(group: []const u8) ?Entry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.group, group)) return entry;
    }
    return null;
}

pub fn find(group: []const u8) ?Print {
    return if (findEntry(group)) |entry| entry.print else null;
}
