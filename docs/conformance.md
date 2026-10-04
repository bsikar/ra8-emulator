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
| barrier | 24 |
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
| dp_shifted | 48 |
| shift_reg | 26 |
| add_sub_wide | 22 |
| long_mul | 26 |
| mrs_msr | 62 |
| ldst_reg_wide | 37 |
| bitfield | 27 |
| mul_acc | 23 |
| saturate | 31 |
| misc_wide | 21 |
| extend_wide | 30 |
| pkh | 22 |
| parallel | 36 |
| sel | 23 |
| sat_arith | 30 |
| extend_b16 | 22 |
| sat16 | 24 |
| usad8 | 22 |
| umaal | 20 |
| dsp_mul16 | 27 |
| dsp_dual | 30 |
| dsp_mulhi | 33 |
| dsp_long_mul | 28 |
| csel | 37 |
| lob | 34 |
| long_shift | 23 |
| long_shift_reg | 34 |
| long_shift_sat | 51 |
| long_shift_sat64 | 50 |
| udf | 6 |
| bkpt | 3 |
| svc | 3 |
| table_branch | 23 |
| blxns | 11 |
| bxns | 14 |
| sg | 17 |
| tt | 26 |
| imm_logic | 30 |
| imm_arith | 35 |
| branch_wide | 45 |
| branch_future | 22 |
| ldst_wide | 47 |
| ldr_literal_wide | 33 |
| preload | 29 |
| fp_arith | 40 |
| fp_unary | 44 |
| fp_system | 38 |
| fp_convert | 39 |
| fp_directed | 48 |
| fp_move | 26 |
| vscclrm | 24 |
| vlldm_vlstm | 22 |
| vlldm_vlstm_t2 | 11 |
| fp_mem | 36 |
| mve_vpst | 17 |
| mve_int | 27 |
| mve_int_pair | 68 |
| mve_int_shift | 52 |
| mve_int_mulh | 39 |
| mve_int_vmla | 23 |
| mve_int_scalar | 42 |
| mve_vcmp | 55 |
| mve_vpred | 20 |
| mve_vctp | 24 |
| mve_lob_tp | 27 |
| mve_vdup | 18 |
| mve_lane_move | 26 |
| mve_lane_pair | 19 |
| mve_vmaxv | 30 |
| mve_int_vqdmlah | 43 |
| mve_vldr | missing |
| mve_vldr_wide | missing |
| mve_gather | missing |
| mve_gather64 | missing |
| mve_gather_imm | missing |
| mve_vld_il | missing |
| mve_float | missing |
| mve_float_scalar | missing |
| mve_vcmp_fp | 51 |
| mve_float_fma | missing |
| mve_float_unary | 26 |
| mve_float_cvt_half | 37 |
| mve_float_cvt_int | 56 |
| mve_float_cvt_fixed | missing |
| mve_float_rint | 44 |
| mve_float_maxnm | 29 |
| mve_float_maxnma | 29 |
| mve_float_maxnmv | 43 |
| mve_float_vcadd | missing |
| mve_float_vcmla | missing |
| mve_float_vcmul | missing |
| ldrd_strd | 33 |
| exclusive | 40 |
| acq_rel | 28 |
| clrm | 27 |
| ldm_stm_wide | 41 |
| pac | 38 |
