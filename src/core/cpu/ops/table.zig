//! The decode table: every instruction group the Zig core knows, in the order
//! the decoder tries them.
//!
//! This is the one registration point. A group is a file under
//! src/core/cpu/ops/ holding a `pub const group: op.Group`, plus one line in
//! this list. Groups must not claim each other's encodings; the first one that
//! answers wins, so an overlap is a bug in the group, not an ordering choice.
//! FP and MVE groups go through fp_gate.gated, which runs ExecuteFPCheck().
const op = @import("../op.zig");
const gate = @import("fp_gate.zig");
const Feature = @import("../profile.zig").Feature;
const Instr = @import("../instr.zig").Instr;
const eci_use = @import("eci_use.zig");

pub const groups = [_]op.Group{
    @import("hint.zig").group,
    @import("barrier.zig").group,
    eci(.restarts, @import("push_pop.zig").group),
    @import("sp_arith.zig").group,
    @import("ldr_literal.zig").group,
    @import("ldst_imm.zig").group,
    @import("ldst_reg.zig").group,
    eci(.restarts, @import("ldm_stm.zig").group),
    @import("shift_imm.zig").group,
    @import("add_sub.zig").group,
    @import("dp_reg.zig").group,
    @import("special_data.zig").group,
    @import("cps.zig").group,
    @import("cbz.zig").group,
    @import("extend.zig").group,
    @import("reverse.zig").group,
    @import("it.zig").group,
    @import("branch.zig").group,
    @import("mov_wide.zig").group,
    @import("divide.zig").group,
    @import("dp_shifted.zig").group,
    @import("shift_reg.zig").group,
    @import("add_sub_wide.zig").group,
    @import("long_mul.zig").group,
    @import("mrs_msr.zig").group,
    @import("ldst_reg_wide.zig").group,
    @import("bitfield.zig").group,
    @import("mul_acc.zig").group,
    @import("saturate.zig").group,
    @import("misc_wide.zig").group,
    @import("extend_wide.zig").group,
    @import("pkh.zig").group,
    @import("parallel.zig").group,
    @import("sel.zig").group,
    @import("sat_arith.zig").group,
    @import("extend_b16.zig").group,
    @import("sat16.zig").group,
    @import("usad8.zig").group,
    @import("umaal.zig").group,
    @import("dsp_mul16.zig").group,
    @import("dsp_dual.zig").group,
    @import("dsp_mulhi.zig").group,
    @import("dsp_long_mul.zig").group,
    needs(.v8_1m, @import("csel.zig").group),
    eciBy(eci_use.lob, needs(.lob, @import("lob.zig").group)),
    needs(.mve, @import("long_shift.zig").group),
    needs(.mve, @import("long_shift_reg.zig").group),
    needs(.mve, @import("long_shift_sat.zig").group),
    needs(.mve, @import("long_shift_sat64.zig").group),
    @import("udf.zig").group,
    eci(.keeps, @import("bkpt.zig").group),
    @import("svc.zig").group,
    @import("table_branch.zig").group,
    @import("blxns.zig").group,
    @import("bxns.zig").group,
    @import("sg.zig").group,
    @import("tt.zig").group,
    @import("imm_logic.zig").group,
    @import("imm_arith.zig").group,
    @import("branch_wide.zig").group,
    needs(.lob, @import("branch_future.zig").group),
    @import("ldst_wide.zig").group,
    @import("ldr_literal_wide.zig").group,
    @import("preload.zig").group,
    gate.gated(@import("fp_arith.zig").group),
    gate.gated(@import("fp_unary.zig").group),
    gate.gated(@import("fp_system.zig").group),
    gate.gated(@import("fp_convert.zig").group),
    gate.gated(@import("fp_directed.zig").group),
    gate.gated(@import("fp_move.zig").group),
    needs(.v8_1m, @import("vscclrm.zig").group),
    @import("vlldm_vlstm.zig").group,
    needs(.v8_1m, @import("vlldm_vlstm.zig").group_t2),
    eciBy(eci_use.fpMem, gate.gatedFpMemory(@import("fp_mem.zig").group)),
    beatWise(@import("mve_vpst.zig").group),
    beatWise(@import("mve_int.zig").group),
    beatWise(@import("mve_bitwise.zig").group),
    beatWise(@import("mve_modimm.zig").group),
    beatWise(@import("mve_widen.zig").group),
    beatWise(@import("mve_shift_imm.zig").group),
    beatWise(@import("mve_int_pair.zig").group),
    beatWise(@import("mve_int_shift.zig").group),
    beatWise(@import("mve_int_mulh.zig").group),
    needs(.mve, gate.gated(@import("mve_int_vmla.zig").group)),
    beatWise(@import("mve_int_scalar.zig").group),
    beatWise(@import("mve_vcmp.zig").group),
    beatWise(@import("mve_vpred.zig").group),
    beatWise(@import("mve_vctp.zig").group),
    eciBy(eci_use.lobTp, needs(.mve, gate.gated(@import("mve_lob_tp.zig").group))),
    beatWise(@import("mve_vdup.zig").group),
    beatWise(@import("mve_lane_move.zig").group),
    beatWise(@import("mve_lane_pair.zig").group),
    beatWise(@import("mve_vmaxv.zig").group),
    beatWise(@import("mve_reduce.zig").group),
    beatWise(@import("mve_int_vqdmlah.zig").group),
    beatWise(@import("mve_vldr.zig").group),
    beatWise(@import("mve_vldr_wide.zig").group),
    beatWise(@import("mve_gather.zig").group),
    beatWise(@import("mve_gather64.zig").group),
    beatWise(@import("mve_gather_imm.zig").group),
    beatWise(@import("mve_vld_il.zig").group),
    beatWise(@import("mve_float.zig").group),
    beatWise(@import("mve_float_scalar.zig").group),
    beatWise(@import("mve_vcmp_fp.zig").group),
    beatWise(@import("mve_float_fma.zig").group),
    beatWise(@import("mve_float_unary.zig").group),
    beatWise(@import("mve_float_cvt_half.zig").group),
    beatWise(@import("mve_float_cvt_int.zig").group),
    beatWise(@import("mve_float_cvt_fixed.zig").group),
    beatWise(@import("mve_float_rint.zig").group),
    beatWise(@import("mve_float_maxnm.zig").group),
    beatWise(@import("mve_float_maxnma.zig").group),
    beatWise(@import("mve_float_maxnmv.zig").group),
    beatWise(@import("mve_float_vcadd.zig").group),
    beatWise(@import("mve_float_vcmla.zig").group),
    beatWise(@import("mve_float_vcmul.zig").group),
    @import("ldrd_strd.zig").group,
    @import("exclusive.zig").group,
    @import("acq_rel.zig").group,
    needs(.v8_1m, @import("clrm.zig").group),
    eci(.restarts, @import("ldm_stm_wide.zig").group),
    needs(.v8_1m, @import("pac.zig").group),
};

fn needs(comptime feature: Feature, comptime group: op.Group) op.Group {
    var tagged = group;
    tagged.needs = feature;
    return tagged;
}

/// An MVE group whose encodings are all beat-wise (RA8EMU-453).
fn beatWise(comptime group: op.Group) op.Group {
    return eci(.beat_wise, needs(.mve, gate.gated(group)));
}

fn eci(comptime use: op.Eci, comptime group: op.Group) op.Group {
    var tagged = group;
    tagged.eci = use;
    return tagged;
}

fn eciBy(comptime of: *const fn (instr: Instr) op.Eci, comptime group: op.Group) op.Group {
    var tagged = group;
    tagged.eci_of = of;
    return tagged;
}
