//! The printer table: which decode group each printer covers, by the group's
//! name in src/chip/core/cpu/ops/table.zig. A group with no entry here has no text
//! yet, and disasm.one returns null for it.
const acq_rel = @import("acq_rel.zig");
const arith = @import("imm/arith.zig");
const b16 = @import("extend/b16.zig");
const barrier = @import("barrier.zig");
const bitfield = @import("bitfield.zig");
const bkpt = @import("bkpt.zig");
const blxns = @import("blxns.zig");
const branch = @import("branch/branch.zig");
const bxns = @import("bxns.zig");
const cbz = @import("cbz.zig");
const clrm = @import("clrm.zig");
const cps = @import("cps.zig");
const csel = @import("csel.zig");
const divide = @import("divide.zig");
const dual = @import("dsp/dual.zig");
const exclusive = @import("exclusive.zig");
const extend = @import("extend/extend.zig");
const fixed = @import("mve/float/cvt/fixed.zig");
const float = @import("mve/float/float.zig");
const fma = @import("mve/float/fma.zig");
const fp = @import("mve/vcmp/fp.zig");
const fp_api = @import("fp.zig");
const future = @import("branch/future.zig");
const gather = @import("mve/gather/gather.zig");
const gather64 = @import("mve/gather64.zig");
const half = @import("mve/float/cvt/half.zig");
const hint = @import("hint.zig");
const imm = @import("shift/imm.zig");
const imm_api = @import("ldst/imm.zig");
const imm_api2 = @import("mve/gather/imm.zig");
const int = @import("mve/float/cvt/int.zig");
const int_api = @import("mve/int/int.zig");
const it = @import("it.zig");
const ldrd_strd = @import("ldrd_strd.zig");
const literal = @import("ldr/literal/literal.zig");
const lob = @import("lob.zig");
const lob_tp = @import("mve/lob_tp.zig");
const logic = @import("imm/logic.zig");
const long_mul = @import("dsp/long_mul.zig");
const maxnm = @import("mve/float/maxnm.zig");
const maxnma = @import("mve/float/maxnma.zig");
const maxnmv = @import("mve/float/maxnmv.zig");
const misc_wide = @import("misc_wide.zig");
const mov_wide = @import("mov_wide.zig");
const move = @import("mve/lane/move.zig");
const mrs_msr = @import("mrs_msr.zig");
const mul = @import("long/mul.zig");
const mul16 = @import("dsp/mul16.zig");
const mul_acc = @import("mul_acc.zig");
const mulh = @import("mve/int/mulh.zig");
const mulhi = @import("dsp/mulhi.zig");
const pac = @import("pac.zig");
const pair = @import("mve/lane/pair.zig");
const pair_api = @import("mve/int/pair.zig");
const parallel = @import("parallel.zig");
const pkh = @import("pkh.zig");
const preload = @import("preload.zig");
const push_pop = @import("push_pop.zig");
const reg = @import("dp/reg.zig");
const reg_api = @import("ldst/reg/reg.zig");
const reg_api2 = @import("shift/reg.zig");
const reg_api3 = @import("long/shift/reg.zig");
const reverse = @import("reverse.zig");
const rint = @import("mve/float/rint.zig");
const sat = @import("long/shift/sat.zig");
const sat16 = @import("sat16.zig");
const sat64 = @import("long/shift/sat64.zig");
const sat_arith = @import("sat_arith.zig");
const saturate = @import("saturate.zig");
const scalar = @import("mve/int/scalar.zig");
const scalar_api = @import("mve/float/scalar.zig");
const sel = @import("sel.zig");
const sg = @import("sg.zig");
const shift = @import("long/shift/shift.zig");
const shift_api = @import("mve/int/shift.zig");
const shifted = @import("dp/shifted.zig");
const sp_arith = @import("sp_arith.zig");
const special_data = @import("special_data.zig");
const stm = @import("ldm/stm/stm.zig");
const sub = @import("add/sub/sub.zig");
const svc = @import("svc.zig");
const table_api = @import("branch/table.zig");
const tt = @import("tt.zig");
const udf = @import("udf.zig");
const umaal = @import("umaal.zig");
const unary = @import("mve/float/unary.zig");
const usad8 = @import("usad8.zig");
const vcadd = @import("mve/float/vcadd.zig");
const vcmla = @import("mve/float/vcmla.zig");
const vcmp = @import("mve/vcmp/vcmp.zig");
const vcmul = @import("mve/float/vcmul.zig");
const vctp = @import("mve/vctp.zig");
const vdup = @import("mve/vdup.zig");
const vld_il = @import("mve/vld_il.zig");
const vldr = @import("mve/vldr/vldr.zig");
const vlldm_vlstm = @import("vlldm_vlstm.zig");
const vmaxv = @import("mve/vmaxv.zig");
const vmla = @import("mve/int/vmla.zig");
const vpred = @import("mve/vpred.zig");
const vpst = @import("mve/vpst.zig");
const vqdmlah = @import("mve/int/vqdmlah.zig");
const vscclrm = @import("vscclrm.zig");
const wide = @import("add/sub/wide.zig");
const wide_api = @import("extend/wide.zig");
const wide_api2 = @import("ldst/wide.zig");
const wide_api3 = @import("ldst/reg/wide.zig");
const wide_api4 = @import("ldr/literal/wide.zig");
const wide_api5 = @import("ldm/stm/wide.zig");
const wide_api6 = @import("branch/wide.zig");
const wide_api7 = @import("mve/vldr/wide.zig");

const std = @import("std");

const Instr = @import("../instr.zig").Instr;
const Text = @import("text.zig").Text;

pub const Print = *const fn (instr: Instr, out: *Text) void;
pub const PredicatedPrint = *const fn (instr: Instr, out: *Text, suffix: []const u8) void;

pub const Entry = struct {
    group: []const u8,
    print: Print,
    predicated: ?PredicatedPrint = null,
};

pub const entries = [_]Entry{
    .{ .group = "shift_imm", .print = imm.print },
    .{ .group = "add_sub", .print = sub.print },
    .{ .group = "dp_reg", .print = reg.print },
    .{ .group = "special_data", .print = special_data.print },
    .{ .group = "extend", .print = extend.print },
    .{ .group = "reverse", .print = reverse.print },
    .{ .group = "ldst_imm", .print = imm_api.print },
    .{ .group = "ldst_reg", .print = reg_api.print },
    .{ .group = "sp_arith", .print = sp_arith.print },
    .{ .group = "ldr_literal", .print = literal.print },
    .{ .group = "ldm_stm", .print = stm.print },
    .{ .group = "push_pop", .print = push_pop.print },
    .{ .group = "cbz", .print = cbz.print },
    .{ .group = "branch", .print = branch.print },
    .{ .group = "svc", .print = svc.print },
    .{ .group = "it", .print = it.print },
    .{ .group = "hint", .print = hint.print },
    .{ .group = "blxns", .print = blxns.print },
    .{ .group = "cps", .print = cps.print },
    .{ .group = "imm_arith", .print = arith.print },
    .{ .group = "imm_logic", .print = logic.print },
    .{ .group = "mov_wide", .print = mov_wide.print },
    .{ .group = "add_sub_wide", .print = wide.print },
    .{ .group = "dp_shifted", .print = shifted.print },
    .{ .group = "shift_reg", .print = reg_api2.print },
    .{ .group = "bitfield", .print = bitfield.print },
    .{ .group = "saturate", .print = saturate.print },
    .{ .group = "sat16", .print = sat16.print },
    .{ .group = "extend_wide", .print = wide_api.print },
    .{ .group = "extend_b16", .print = b16.print },
    .{ .group = "divide", .print = divide.print },
    .{ .group = "mul_acc", .print = mul_acc.print },
    .{ .group = "long_mul", .print = mul.print },
    .{ .group = "dsp_mul16", .print = mul16.print },
    .{ .group = "dsp_mulhi", .print = mulhi.print },
    .{ .group = "dsp_long_mul", .print = long_mul.print },
    .{ .group = "sat_arith", .print = sat_arith.print },
    .{ .group = "barrier", .print = barrier.print },
    .{ .group = "preload", .print = preload.print },
    .{ .group = "ldst_wide", .print = wide_api2.print },
    .{ .group = "ldst_reg_wide", .print = wide_api3.print },
    .{ .group = "ldr_literal_wide", .print = wide_api4.print },
    .{ .group = "ldrd_strd", .print = ldrd_strd.print },
    .{ .group = "ldm_stm_wide", .print = wide_api5.print },
    .{ .group = "exclusive", .print = exclusive.print },
    .{ .group = "acq_rel", .print = acq_rel.print },
    .{ .group = "table_branch", .print = table_api.print },
    .{ .group = "branch_wide", .print = wide_api6.print },
    .{ .group = "mrs_msr", .print = mrs_msr.print },
    .{ .group = "misc_wide", .print = misc_wide.print },
    .{ .group = "sg", .print = sg.print },
    .{ .group = "tt", .print = tt.print },
    .{ .group = "udf", .print = udf.print },
    .{ .group = "bkpt", .print = bkpt.print },
    .{ .group = "bxns", .print = bxns.print },
    .{ .group = "sel", .print = sel.print },
    .{ .group = "pkh", .print = pkh.print },
    .{ .group = "umaal", .print = umaal.print },
    .{ .group = "usad8", .print = usad8.print },
    .{ .group = "parallel", .print = parallel.print },
    .{ .group = "dsp_dual", .print = dual.print },
    .{ .group = "csel", .print = csel.print },
    .{ .group = "clrm", .print = clrm.print },
    .{ .group = "vscclrm", .print = vscclrm.print },
    .{ .group = "long_shift", .print = shift.print },
    .{ .group = "long_shift_reg", .print = reg_api3.print },
    .{ .group = "long_shift_sat", .print = sat.print },
    .{ .group = "long_shift_sat64", .print = sat64.print },
    .{ .group = "lob", .print = lob.print },
    .{ .group = "mve_lob_tp", .print = lob_tp.print },
    .{ .group = "mve_vpred", .print = vpred.print, .predicated = vpred.printPredicated },
    .{ .group = "mve_vctp", .print = vctp.print },
    .{ .group = "mve_vdup", .print = vdup.print, .predicated = vdup.printPredicated },
    .{ .group = "mve_lane_pair", .print = pair.print },
    .{ .group = "mve_lane_move", .print = move.print },
    .{ .group = "mve_vmaxv", .print = vmaxv.print, .predicated = vmaxv.printPredicated },
    .{ .group = "mve_int_pair", .print = pair_api.print, .predicated = pair_api.printPredicated },
    .{ .group = "mve_float", .print = float.print, .predicated = float.printPredicated },
    .{ .group = "mve_int_mulh", .print = mulh.print, .predicated = mulh.printPredicated },
    .{ .group = "mve_int_shift", .print = shift_api.print, .predicated = shift_api.printPredicated },
    .{ .group = "mve_int_vmla", .print = vmla.print, .predicated = vmla.printPredicated },
    .{ .group = "mve_int_vqdmlah", .print = vqdmlah.print, .predicated = vqdmlah.printPredicated },
    .{ .group = "mve_int_scalar", .print = scalar.print, .predicated = scalar.printPredicated },
    .{ .group = "mve_vld_il", .print = vld_il.print },
    .{ .group = "mve_vldr", .print = vldr.print, .predicated = vldr.printPredicated },
    .{ .group = "mve_vldr_wide", .print = wide_api7.print, .predicated = wide_api7.printPredicated },
    .{ .group = "mve_gather", .print = gather.print, .predicated = gather.printPredicated },
    .{ .group = "mve_gather64", .print = gather64.print, .predicated = gather64.printPredicated },
    .{ .group = "mve_gather_imm", .print = imm_api2.print, .predicated = imm_api2.printPredicated },
    .{ .group = "mve_float_cvt_fixed", .print = fixed.print, .predicated = fixed.printPredicated },
    .{ .group = "mve_float_cvt_half", .print = half.print, .predicated = half.printPredicated },
    .{ .group = "mve_float_cvt_int", .print = int.print, .predicated = int.printPredicated },
    .{ .group = "mve_float_fma", .print = fma.print, .predicated = fma.printPredicated },
    .{ .group = "mve_float_maxnm", .print = maxnm.print, .predicated = maxnm.printPredicated },
    .{ .group = "mve_float_maxnma", .print = maxnma.print, .predicated = maxnma.printPredicated },
    .{ .group = "mve_float_maxnmv", .print = maxnmv.print, .predicated = maxnmv.printPredicated },
    .{ .group = "mve_float_rint", .print = rint.print, .predicated = rint.printPredicated },
    .{ .group = "mve_float_unary", .print = unary.print, .predicated = unary.printPredicated },
    .{ .group = "mve_float_scalar", .print = scalar_api.print, .predicated = scalar_api.printPredicated },
    .{ .group = "mve_float_vcadd", .print = vcadd.print, .predicated = vcadd.printPredicated },
    .{ .group = "mve_float_vcmla", .print = vcmla.print, .predicated = vcmla.printPredicated },
    .{ .group = "mve_float_vcmul", .print = vcmul.print, .predicated = vcmul.printPredicated },
    .{ .group = "mve_vpst", .print = vpst.print },
    .{ .group = "mve_vcmp", .print = vcmp.print, .predicated = vcmp.printPredicated },
    .{ .group = "mve_vcmp_fp", .print = fp.print, .predicated = fp.printPredicated },
    .{ .group = "mve_int", .print = int_api.print, .predicated = int_api.printPredicated },
    .{ .group = "branch_future", .print = future.print },
    .{ .group = "pac", .print = pac.print },
    .{ .group = "vlldm_vlstm", .print = vlldm_vlstm.print },
    .{ .group = "vlldm_vlstm_t2", .print = vlldm_vlstm.print },
    .{ .group = "fp_arith", .print = fp_api.arith },
    .{ .group = "fp_unary", .print = fp_api.unary },
    .{ .group = "fp_system", .print = fp_api.system },
    .{ .group = "fp_convert", .print = fp_api.convert },
    .{ .group = "fp_directed", .print = fp_api.directed },
    .{ .group = "fp_move", .print = fp_api.move },
    .{ .group = "fp_mem", .print = fp_api.mem },
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
