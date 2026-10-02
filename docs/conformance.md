# Conformance coverage

Every encoding the Zig core's semantics claim, and how many vectors from
the Arm ARM (DDI0553) pseudocode cover it. Generated from
src/core/cpu/conformance/suite.zig; `zig build test` fails when this file
is stale or an encoding is missing. Regenerate with
`RA8_BLESS_CONFORMANCE=1 zig build test`.

| Encoding | Vectors |
|---|---|
| VNEG.F32 T1 | 7 |
| VNEG.F64 T1 | 5 |
| VABS.F32 T1 | 5 |
| VABS.F64 T1 | 4 |
| VADD.F32 T1 | 18 |
| VADD.F64 T1 | 3 |
| VSUB.F32 T1 | 10 |
| VSUB.F64 T1 | 3 |
| VMUL.F32 T2 | 19 |
| VMUL.F64 T2 | 4 |
| VNMUL.F32 T2 | 6 |
| VNMUL.F64 T2 | 2 |
| VMLA.F32 T2 | 7 |
| VMLA.F64 T2 | 1 |
| VMLS.F32 T2 | 5 |
| VMLS.F64 T2 | 1 |
| VNMLA.F32 T2 | 3 |
| VNMLA.F64 T2 | 1 |
| VNMLS.F32 T2 | 3 |
| VNMLS.F64 T2 | 1 |
| VFMA.F32 T2 | 21 |
| VFMA.F64 T2 | 3 |
| VFMS.F32 T2 | 4 |
| VFMS.F64 T2 | 1 |
| VFNMA.F32 T2 | 3 |
| VFNMA.F64 T2 | 1 |
| VFNMS.F32 T2 | 3 |
| VFNMS.F64 T2 | 1 |
| VDIV.F32 T1 | 27 |
| VDIV.F64 T1 | 6 |
| VSQRT.F32 T1 | 20 |
| VSQRT.F64 T1 | 6 |
| VCMP.F32 T1 | 15 |
| VCMP.F32 T2 | 3 |
| VCMPE.F32 T1 | 2 |
| VCMPE.F32 T2 | 2 |
| VCMP.F64 T1 | 5 |
| VCMP.F64 T2 | 1 |
| VCMPE.F64 T1 | 1 |
| VCMPE.F64 T2 | 1 |
| VCVT.F64.F32 T1 | 10 |
| VCVT.F32.F64 T1 | 17 |
| VCVT.S32.F32 T1 | 14 |
| VCVTR.S32.F32 T1 | 7 |
| VCVT.U32.F32 T1 | 6 |
| VCVTR.U32.F32 T1 | 2 |
| VCVT.S32.F64 T1 | 4 |
| VCVTR.S32.F64 T1 | 1 |
| VCVT.U32.F64 T1 | 3 |
| VCVT.F32.S32 T1 | 8 |
| VCVT.F32.U32 T1 | 3 |
| VCVT.F64.S32 T1 | 2 |
| VCVT.F64.U32 T1 | 2 |
| VCVTA.S32.F32 T1 | 7 |
| VCVTA.U32.F32 T1 | 2 |
| VCVTN.S32.F32 T1 | 3 |
| VCVTN.U32.F32 T1 | 1 |
| VCVTP.S32.F32 T1 | 2 |
| VCVTP.U32.F32 T1 | 1 |
| VCVTM.S32.F32 T1 | 3 |
| VCVTM.U32.F32 T1 | 1 |
| VCVTA.S32.F64 T1 | 2 |
| VCVTA.U32.F64 T1 | 1 |
| VCVTN.S32.F64 T1 | 1 |
| VCVTN.U32.F64 T1 | 1 |
| VCVTP.S32.F64 T1 | 1 |
| VCVTP.U32.F64 T1 | 1 |
| VCVTM.S32.F64 T1 | 2 |
| VCVTM.U32.F64 T1 | 1 |
| VRINTA.F32 T1 | 8 |
| VRINTN.F32 T1 | 4 |
| VRINTP.F32 T1 | 4 |
| VRINTM.F32 T1 | 4 |
| VRINTZ.F32 T1 | 3 |
| VRINTR.F32 T1 | 2 |
| VRINTX.F32 T1 | 4 |
| VRINTA.F64 T1 | 1 |
| VRINTN.F64 T1 | 2 |
| VRINTP.F64 T1 | 1 |
| VRINTM.F64 T1 | 1 |
| VRINTZ.F64 T1 | 1 |
| VRINTR.F64 T1 | 1 |
| VRINTX.F64 T1 | 2 |
| VMAXNM.F32 T1 | 15 |
| VMINNM.F32 T1 | 9 |
| VMAXNM.F64 T1 | 2 |
| VMINNM.F64 T1 | 2 |
| VSELEQ.F32 T1 | 4 |
| VSELVS.F32 T1 | 2 |
| VSELGE.F32 T1 | 4 |
| VSELGT.F32 T1 | 4 |
| VSELEQ.F64 T1 | 2 |
| VSELVS.F64 T1 | 3 |
| VSELGE.F64 T1 | 2 |
| VSELGT.F64 T1 | 2 |
| VCVT.S32.F32 fbits T1 | 7 |
| VCVT.U32.F32 fbits T1 | 3 |
| VCVT.S16.F32 fbits T1 | 6 |
| VCVT.U16.F32 fbits T1 | 4 |
| VCVT.S32.F64 fbits T1 | 2 |
| VCVT.U32.F64 fbits T1 | 1 |
| VCVT.S16.F64 fbits T1 | 2 |
| VCVT.U16.F64 fbits T1 | 2 |
| VCVT.F32.S32 fbits T1 | 4 |
| VCVT.F32.U32 fbits T1 | 2 |
| VCVT.F32.S16 fbits T1 | 3 |
| VCVT.F32.U16 fbits T1 | 3 |
| VCVT.F64.S32 fbits T1 | 2 |
| VCVT.F64.U32 fbits T1 | 1 |
| VCVT.F64.S16 fbits T1 | 1 |
| VCVT.F64.U16 fbits T1 | 1 |
| VCVTB.F16.F32 T1 | 25 |
| VCVTT.F16.F32 T1 | 1 |
| VCVTB.F16.F64 T1 | 3 |
| VCVTT.F16.F64 T1 | 2 |
| VCVTB.F32.F16 T1 | 10 |
| VCVTT.F32.F16 T1 | 2 |
| VCVTB.F64.F16 T1 | 3 |
| VCVTT.F64.F16 T1 | 2 |
| VMOV.F32 imm T1 | 10 |
| VMOV.F64 imm T1 | 8 |
| VMSR T1 | 9 |
| VMRS T1 | 2 |
| VMRS APSR_nzcv T1 | 3 |
| VLDM.F64 T1 | 12 |
| VLDM.F32 T2 | 5 |
| VSTM.F64 T1 | 2 |
| VSTM.F32 T2 | 2 |
| VPUSH.F64 T1 | 1 |
| VPUSH.F32 T2 | 1 |
| VPOP.F64 T1 | 1 |
| VPOP.F32 T2 | 1 |
| VLDR.F64 T1 | 3 |
| VLDR.F32 T2 | 2 |
| VSTR.F64 T1 | 1 |
| VSTR.F32 T2 | 2 |
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
