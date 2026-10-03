# Conformance coverage

Every encoding the Zig core's semantics claim, and how many vectors from
the Arm ARM (DDI0553) pseudocode cover it. Generated from
src/core/cpu/conformance/suite.zig; `zig build test` fails when this file
is stale or a semantics encoding is missing. Regenerate with
`RA8_BLESS_CONFORMANCE=1 zig build test`.

| Encoding | Vectors |
|---|---|
| VNEG (floating-point) | 12 |
| VABS (floating-point) | 9 |
| VADD (floating-point) | 21 |
| VSUB (floating-point) | 13 |
| VMUL (floating-point) | 23 |
| VNMUL (floating-point) | 8 |
| VMLA (floating-point) | 8 |
| VMLS (floating-point) | 6 |
| VNMLA (floating-point) | 4 |
| VNMLS (floating-point) | 4 |
| VFMA, VFMS (floating-point) | 29 |
| VFNMA | 4 |
| VFNMS | 4 |
| VDIV | 33 |
| VSQRT | 26 |
| VCMP | 24 |
| VCMPE | 6 |
| VCVT (between double-precision and single-precision) | 27 |
| VCVT (between floating-point and integer) | 27 |
| VCVTR | 10 |
| VCVT (integer to floating-point) | 15 |
| VCVTA | 12 |
| VCVTN | 6 |
| VCVTP | 5 |
| VCVTM | 7 |
| VRINTA | 9 |
| VRINTN | 6 |
| VRINTP | 5 |
| VRINTM | 5 |
| VRINTZ | 4 |
| VRINTR | 3 |
| VRINTX | 6 |
| VMAXNM | 17 |
| VMINNM | 11 |
| VSEL | 23 |
| VCVT (between floating-point and fixed-point) | 44 |
| VCVTB | 41 |
| VCVTT | 7 |
| VMOV (immediate) | 18 |
| VMSR | 9 |
| VMRS | 5 |
| VLDM | 17 |
| VSTM | 4 |
| VPUSH | 2 |
| VPOP | 2 |
| VLDR | 5 |
| VSTR | 3 |
| VADD (vector) T1 | 4 |
| VSUB (vector) T1 | 2 |
| VMUL (vector) T1 | 3 |
| VQADD (vector) T1 | 4 |
| VQSUB (vector) T1 | 4 |
| VABD (vector) T1 | 3 |
| VMAX T1 | 3 |
| VMIN T1 | 3 |
| VHADD (vector) T1 | 2 |
| VRHADD T1 | 2 |
| VHSUB (vector) T1 | 2 |
| VSHL (vector) T1 | 3 |
| VRSHL T1 | 2 |
| VQSHL (vector) T1 | 2 |
| VQRSHL T1 | 2 |
| VSHL (immediate) T1 | 2 |
| VSHR T1 | 2 |
| VRSHR T1 | 2 |
| VQSHL (immediate) T1 | 2 |
| VMOVN T1 | 2 |
| VQMOVN T1 | 2 |
| VQMOVUN T1 | 2 |
| VSHRN T1 | 2 |
| VRSHRN T1 | 2 |
| VQSHRN T1 | 2 |
| VQRSHRN T1 | 2 |
| VQSHRUN T1 | 2 |
| VMOVL T1 | 3 |
| VSHLL T1 | 3 |
| VSRI T1 | 4 |
| VSLI T1 | 4 |
| VQSHLU T1 | 4 |
| VADDV T1 | 4 |
| VADDLV T1 | 2 |
| VMLADAV T1 | 4 |
| VMLSDAV T1 | 2 |
| VMLALDAV T1 | 3 |
| VMLSLDAV T1 | 2 |
| VMULH T1 | 3 |
| VRMULH T1 | 3 |
| VQDMULH T1 | 3 |
| VQRDMULH T1 | 3 |
| VMLA T1 | 3 |
| VMLAS T1 | 3 |
| VQDMLAH T1 | 3 |
| VQRDMLAH T1 | 3 |
| VQDMLASH T1 | 2 |
| VQRDMLASH T1 | 2 |
| VCMP T1 | 2 |
| VCMP T2 | 2 |
| VCMP T3 | 4 |
| VCMP T4 | 1 |
| VCMP T5 | 1 |
| VCMP T6 | 1 |
| VPT T1 | 1 |
| VPT T2 | 1 |
| VPT T3 | 1 |
| VPT T4 | 1 |
| VPT T5 | 1 |
| VPT T6 | 1 |
| VMAXV T1 | 4 |
| VMINV T1 | 3 |
| VMAXAV T1 | 2 |
| VMINAV T1 | 2 |
| VBRSR T1 | 9 |
| VLDRB.8 | 2 |
| VLDRH.16 | 2 |
| VLDRW.32 | 4 |
| VSTRB.8 | 1 |
| VSTRH.16 | 1 |
| VSTRW.32 | 4 |
| VLDRB.S16 | 2 |
| VLDRB.U16 | 1 |
| VLDRB.S32 | 1 |
| VLDRB.U32 | 1 |
| VLDRH.S32 | 3 |
| VLDRH.U32 | 1 |
| VSTRB.16 | 1 |
| VSTRB.32 | 1 |
| VSTRH.32 | 3 |
| VLDRB.U8 gather | 1 |
| VLDRB.S16 gather | 1 |
| VLDRB.U16 gather | 1 |
| VLDRB.S32 gather | 1 |
| VLDRB.U32 gather | 1 |
| VLDRH.U16 gather | 2 |
| VLDRH.S32 gather | 2 |
| VLDRH.U32 gather | 1 |
| VLDRW.U32 gather | 3 |
| VSTRB.8 scatter | 1 |
| VSTRB.16 scatter | 1 |
| VSTRB.32 scatter | 1 |
| VSTRH.16 scatter | 1 |
| VSTRH.32 scatter | 1 |
| VSTRW.32 scatter | 4 |
| VLDRD.U64 gather | 6 |
| VSTRD.64 scatter | 5 |
| VLDRW.U32 vector base | 5 |
| VLDRD.U64 vector base | 2 |
| VSTRW.32 vector base | 4 |
| VSTRD.64 vector base | 2 |
| VLD20 | 4 |
| VLD21 | 2 |
| VLD40 | 2 |
| VLD41 | 2 |
| VLD42 | 2 |
| VLD43 | 2 |
| VST20 | 4 |
| VST21 | 2 |
| VST40 | 2 |
| VST41 | 2 |
| VST42 | 2 |
| VST43 | 2 |
| VADD.F16 (MVE) T1 | 3 |
| VADD.F32 (MVE) T1 | 1 |
| VSUB.F16 (MVE) T1 | 1 |
| VSUB.F32 (MVE) T1 | 1 |
| VMUL.F16 (MVE) T1 | 1 |
| VMUL.F32 (MVE) T1 | 1 |
| VFMA.F16 (MVE) T1 | 1 |
| VFMA.F32 (MVE) T1 | 1 |
| VFMS.F16 (MVE) T1 | 1 |
| VFMS.F32 (MVE) T1 | 1 |
| VFMAS.F16 (MVE) T1 | 1 |
| VFMAS.F32 (MVE) T1 | 1 |
| VABD.F16 (MVE) T1 | 1 |
| VABD.F32 (MVE) T1 | 1 |
| VABS.F16 (MVE) T1 | 1 |
| VABS.F32 (MVE) T1 | 1 |
| VNEG.F16 (MVE) T1 | 1 |
| VNEG.F32 (MVE) T1 | 1 |
| VCMP.F16 (MVE) T1 | 2 |
| VCMP.F32 (MVE) T1 | 7 |
| VCVTB.F16.F32 (MVE) T1 | 2 |
| VCVTT.F16.F32 (MVE) T1 | 1 |
| VCVTB.F32.F16 (MVE) T1 | 1 |
| VCVTT.F32.F16 (MVE) T1 | 1 |
| VCVT.S32.F32 (MVE) T1 | 1 |
| VCVT.U32.F32 (MVE) T1 | 1 |
| VCVT.S16.F16 (MVE) T1 | 1 |
| VCVT.U16.F16 (MVE) T1 | 1 |
| VCVTA.S32.F32 (MVE) T1 | 1 |
| VCVTN.S32.F32 (MVE) T1 | 1 |
| VCVTP.S32.F32 (MVE) T1 | 1 |
| VCVTM.S32.F32 (MVE) T1 | 1 |
| VCVTA.U16.F16 (MVE) T1 | 1 |
| VCVT.F32.S32 (MVE) T1 | 1 |
| VCVT.F32.U32 (MVE) T1 | 1 |
| VCVT.F16.S16 (MVE) T1 | 1 |
| VCVT.F16.U16 (MVE) T1 | 1 |
| VCVT.S32.F32 (MVE, fixed-point) T1 | 1 |
| VCVT.F32.U32 (MVE, fixed-point) T1 | 1 |
| VCVT.S16.F16 (MVE, fixed-point) T1 | 1 |
| VCVT.F16.S16 (MVE, fixed-point) T1 | 1 |
| VRINTA (MVE) T1 | 1 |
| VRINTN (MVE) T1 | 1 |
| VRINTP (MVE) T1 | 1 |
| VRINTM (MVE) T1 | 2 |
| VRINTZ (MVE) T1 | 2 |
| VRINTX (MVE) T1 | 2 |
| VMAXNM (MVE) T1 | 1 |
| VMINNM (MVE) T1 | 1 |
| VMAXNMA (MVE) T1 | 1 |
| VMINNMA (MVE) T1 | 1 |
| VMAXNMV (MVE) T1 | 2 |
| VMINNMV (MVE) T1 | 1 |
| VMAXNMAV (MVE) T1 | 1 |
| VMINNMAV (MVE) T1 | 1 |
| VCADD (MVE, floating-point) T1 | 4 |
| VCMLA (MVE) T1 | 6 |
| VCMUL (MVE) T1 | 5 |
| VADD (MVE, floating-point, by scalar) T2 | 1 |
| VSUB (MVE, floating-point, by scalar) T2 | 1 |
| VMUL (MVE, floating-point, by scalar) T2 | 1 |
| VFMA (MVE, floating-point, by scalar) T1 | 1 |
| VFMAS (MVE, floating-point, by scalar) T1 | 1 |
| VCMP (MVE, floating-point, by scalar) T2 | 2 |

## Decode table

Every instruction group the Zig decode table registers
(src/core/cpu/ops/table.zig), and how many conformance vectors name it.
The FP and MVE groups' semantics are covered encoding by encoding in the
table above. A group listed as missing does not fail the build yet.

| Group | Vectors |
|---|---|
| hint | 20 |
| barrier | missing |
| push_pop | 17 |
| sp_arith | 23 |
| ldr_literal | 10 |
| ldst_imm | 28 |
| ldst_reg | 25 |
| ldm_stm | 20 |
| shift_imm | 16 |
| add_sub | 18 |
| dp_reg | 29 |
| special_data | 18 |
| cps | 13 |
| cbz | 7 |
| extend | 7 |
| reverse | 6 |
| it | 8 |
| branch | 18 |
| mov_wide | 18 |
| divide | 22 |
| dp_shifted | missing |
| shift_reg | 26 |
| add_sub_wide | missing |
| long_mul | 26 |
| mrs_msr | missing |
| ldst_reg_wide | missing |
| bitfield | 27 |
| mul_acc | 23 |
| saturate | missing |
| misc_wide | missing |
| extend_wide | missing |
| pkh | missing |
| parallel | missing |
| sel | missing |
| sat_arith | missing |
| extend_b16 | missing |
| sat16 | missing |
| usad8 | missing |
| umaal | missing |
| dsp_mul16 | missing |
| dsp_dual | missing |
| dsp_mulhi | missing |
| dsp_long_mul | missing |
| csel | missing |
| lob | missing |
| long_shift | missing |
| long_shift_reg | missing |
| long_shift_sat | missing |
| long_shift_sat64 | missing |
| udf | 6 |
| bkpt | 3 |
| svc | 3 |
| table_branch | missing |
| blxns | 11 |
| bxns | 14 |
| sg | missing |
| tt | missing |
| imm_logic | missing |
| imm_arith | missing |
| branch_wide | missing |
| branch_future | missing |
| ldst_wide | missing |
| ldr_literal_wide | missing |
| preload | missing |
| fp_arith | missing |
| fp_unary | missing |
| fp_system | missing |
| fp_convert | missing |
| fp_directed | missing |
| fp_move | missing |
| vscclrm | missing |
| vlldm_vlstm | missing |
| vlldm_vlstm_t2 | missing |
| fp_mem | missing |
| mve_vpst | missing |
| mve_int | missing |
| mve_int_pair | missing |
| mve_int_shift | missing |
| mve_int_mulh | missing |
| mve_int_vmla | missing |
| mve_int_scalar | missing |
| mve_vcmp | missing |
| mve_vpred | missing |
| mve_vctp | missing |
| mve_lob_tp | missing |
| mve_vdup | missing |
| mve_lane_move | missing |
| mve_lane_pair | missing |
| mve_vmaxv | missing |
| mve_int_vqdmlah | missing |
| mve_vldr | missing |
| mve_vldr_wide | missing |
| mve_gather | missing |
| mve_gather64 | missing |
| mve_gather_imm | missing |
| mve_vld_il | missing |
| mve_float | missing |
| mve_float_scalar | missing |
| mve_vcmp_fp | missing |
| mve_float_fma | missing |
| mve_float_unary | missing |
| mve_float_cvt_half | missing |
| mve_float_cvt_int | missing |
| mve_float_cvt_fixed | missing |
| mve_float_rint | missing |
| mve_float_maxnm | missing |
| mve_float_maxnma | missing |
| mve_float_maxnmv | missing |
| mve_float_vcadd | missing |
| mve_float_vcmla | missing |
| mve_float_vcmul | missing |
| ldrd_strd | missing |
| exclusive | missing |
| acq_rel | missing |
| clrm | missing |
| ldm_stm_wide | missing |
| pac | missing |
