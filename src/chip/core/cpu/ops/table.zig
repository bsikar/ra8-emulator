//! The decode table: every instruction group the Zig core knows, in the order
//! the decoder tries them.
//!
//! This is the one registration point. A group is a file under
//! src/chip/core/cpu/ops/ holding a `pub const group: op.Group`, plus one line in
//! this list. Groups must not claim each other's encodings; the first one that
//! answers wins, so an overlap is a bug in the group, not an ordering choice.
//! FP and MVE groups go through fp_gate.gated, which runs ExecuteFPCheck().
const acq_rel = @import("acq_rel.zig");
const arith = @import("imm/arith.zig");
const arith_api = @import("fp/arith.zig");
const b16 = @import("extend/b16.zig");
const barrier = @import("barrier.zig");
const bitfield = @import("bitfield.zig");
const bitwise = @import("mve/bitwise.zig");
const bkpt = @import("bkpt.zig");
const blxns = @import("blxns.zig");
const branch = @import("branch/branch.zig");
const bxns = @import("bxns.zig");
const cbz = @import("cbz.zig");
const clrm = @import("clrm.zig");
const convert = @import("fp/convert.zig");
const cps = @import("cps.zig");
const csel = @import("csel.zig");
const directed = @import("fp/directed.zig");
const divide = @import("divide.zig");
const dual = @import("dsp/dual.zig");
const exclusive = @import("exclusive.zig");
const extend = @import("extend/extend.zig");
const fixed = @import("mve/float/cvt/fixed.zig");
const float = @import("mve/float/float.zig");
const fma = @import("mve/float/fma.zig");
const fp = @import("mve/vcmp/fp.zig");
const future = @import("branch/future.zig");
const gather = @import("mve/gather/gather.zig");
const gather64 = @import("mve/gather64.zig");
const half = @import("mve/float/cvt/half.zig");
const hint = @import("hint.zig");
const imm = @import("ldst/imm.zig");
const imm_api = @import("shift/imm.zig");
const imm_api2 = @import("mve/gather/imm.zig");
const int = @import("mve/int/int.zig");
const int_api = @import("mve/float/cvt/int.zig");
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
const mem = @import("fp/mem.zig");
const misc_wide = @import("misc_wide.zig");
const modimm = @import("mve/modimm.zig");
const mov_wide = @import("mov_wide.zig");
const move = @import("fp/move.zig");
const move_api = @import("mve/lane/move.zig");
const mrs_msr = @import("mrs_msr.zig");
const mul = @import("long/mul.zig");
const mul16 = @import("dsp/mul16.zig");
const mul_acc = @import("mul_acc.zig");
const mulh = @import("mve/int/mulh.zig");
const mulhi = @import("dsp/mulhi.zig");
const pac = @import("pac.zig");
const pair = @import("mve/int/pair.zig");
const pair_api = @import("mve/lane/pair.zig");
const parallel = @import("parallel.zig");
const pkh = @import("pkh.zig");
const preload = @import("preload.zig");
const push_pop = @import("push_pop.zig");
const reduce = @import("mve/reduce.zig");
const reg = @import("ldst/reg/reg.zig");
const reg_api = @import("dp/reg.zig");
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
const shift_imm = @import("mve/shift_imm.zig");
const shifted = @import("dp/shifted.zig");
const sp_arith = @import("sp_arith.zig");
const special_data = @import("special_data.zig");
const stm = @import("ldm/stm/stm.zig");
const sub = @import("add/sub/sub.zig");
const svc = @import("svc.zig");
const system = @import("fp/system.zig");
const table_api = @import("branch/table.zig");
const tt = @import("tt.zig");
const udf = @import("udf.zig");
const umaal = @import("umaal.zig");
const unary = @import("fp/unary.zig");
const unary_api = @import("mve/float/unary.zig");
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
const wide_api = @import("ldst/reg/wide.zig");
const wide_api2 = @import("extend/wide.zig");
const wide_api3 = @import("branch/wide.zig");
const wide_api4 = @import("ldst/wide.zig");
const wide_api5 = @import("ldr/literal/wide.zig");
const wide_api6 = @import("mve/vldr/wide.zig");
const wide_api7 = @import("ldm/stm/wide.zig");
const widen = @import("mve/widen.zig");

const eci_use = @import("eci_use.zig");
const Feature = @import("../profile.zig").Feature;
const gate = @import("fp/gate.zig");
const Instr = @import("../instr.zig").Instr;
const op = @import("../op.zig");

pub const groups = [_]op.Group{
    hint.group,
    barrier.group,
    eci(.restarts, push_pop.group),
    sp_arith.group,
    literal.group,
    imm.group,
    reg.group,
    eci(.restarts, stm.group),
    imm_api.group,
    sub.group,
    reg_api.group,
    special_data.group,
    cps.group,
    cbz.group,
    extend.group,
    reverse.group,
    it.group,
    branch.group,
    mov_wide.group,
    divide.group,
    shifted.group,
    reg_api2.group,
    wide.group,
    mul.group,
    mrs_msr.group,
    wide_api.group,
    bitfield.group,
    mul_acc.group,
    saturate.group,
    misc_wide.group,
    wide_api2.group,
    pkh.group,
    parallel.group,
    sel.group,
    sat_arith.group,
    b16.group,
    sat16.group,
    usad8.group,
    umaal.group,
    mul16.group,
    dual.group,
    mulhi.group,
    long_mul.group,
    needs(.v8_1m, csel.group),
    eciBy(eci_use.lob, needs(.lob, lob.group)),
    needs(.mve, shift.group),
    needs(.mve, reg_api3.group),
    needs(.mve, sat.group),
    needs(.mve, sat64.group),
    udf.group,
    eci(.keeps, bkpt.group),
    svc.group,
    table_api.group,
    blxns.group,
    bxns.group,
    sg.group,
    tt.group,
    logic.group,
    arith.group,
    wide_api3.group,
    needs(.lob, future.group),
    wide_api4.group,
    wide_api5.group,
    preload.group,
    gate.gated(arith_api.group),
    gate.gated(unary.group),
    gate.gated(system.group),
    gate.gated(convert.group),
    gate.gated(directed.group),
    gate.gated(move.group),
    needs(.v8_1m, vscclrm.group),
    vlldm_vlstm.group,
    needs(.v8_1m, vlldm_vlstm.group_t2),
    eciBy(eci_use.fpMem, gate.gatedFpMemory(mem.group)),
    beatWise(vpst.group),
    beatWise(int.group),
    beatWise(bitwise.group),
    beatWise(modimm.group),
    beatWise(widen.group),
    beatWise(shift_imm.group),
    beatWise(pair.group),
    beatWise(shift_api.group),
    beatWise(mulh.group),
    needs(.mve, gate.gated(vmla.group)),
    beatWise(scalar.group),
    beatWise(vcmp.group),
    beatWise(vpred.group),
    beatWise(vctp.group),
    eciBy(eci_use.lobTp, needs(.mve, gate.gated(lob_tp.group))),
    beatWise(vdup.group),
    beatWise(move_api.group),
    beatWise(pair_api.group),
    beatWise(vmaxv.group),
    beatWise(reduce.group),
    beatWise(vqdmlah.group),
    beatWise(vldr.group),
    beatWise(wide_api6.group),
    beatWise(gather.group),
    beatWise(gather64.group),
    beatWise(imm_api2.group),
    beatWise(vld_il.group),
    beatWise(float.group),
    beatWise(scalar_api.group),
    beatWise(fp.group),
    beatWise(fma.group),
    beatWise(unary_api.group),
    beatWise(half.group),
    beatWise(int_api.group),
    beatWise(fixed.group),
    beatWise(rint.group),
    beatWise(maxnm.group),
    beatWise(maxnma.group),
    beatWise(maxnmv.group),
    beatWise(vcadd.group),
    beatWise(vcmla.group),
    beatWise(vcmul.group),
    ldrd_strd.group,
    exclusive.group,
    acq_rel.group,
    needs(.v8_1m, clrm.group),
    eci(.restarts, wide_api7.group),
    pac.group,
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
