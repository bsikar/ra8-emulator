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
| VLDRW.32 | 2 |
| VSTRB.8 | 1 |
| VSTRH.16 | 1 |
| VSTRW.32 | 2 |
| VLDRB.S16 | 2 |
| VLDRB.U16 | 1 |
| VLDRB.S32 | 1 |
| VLDRB.U32 | 1 |
| VLDRH.S32 | 1 |
| VLDRH.U32 | 1 |
| VSTRB.16 | 1 |
| VSTRB.32 | 1 |
| VSTRH.32 | 1 |
| VLDRB.U8 gather | 1 |
| VLDRB.S16 gather | 1 |
| VLDRB.U16 gather | 1 |
| VLDRB.S32 gather | 1 |
| VLDRB.U32 gather | 1 |
| VLDRH.U16 gather | 2 |
| VLDRH.S32 gather | 2 |
| VLDRH.U32 gather | 1 |
| VLDRW.U32 gather | 1 |
| VSTRB.8 scatter | 1 |
| VSTRB.16 scatter | 1 |
| VSTRB.32 scatter | 1 |
| VSTRH.16 scatter | 1 |
| VSTRH.32 scatter | 1 |
| VSTRW.32 scatter | 2 |
| VLDRD.U64 gather | 4 |
| VSTRD.64 scatter | 3 |
| VLDRW.U32 vector base | 3 |
| VLDRD.U64 vector base | 2 |
| VSTRW.32 vector base | 2 |
| VSTRD.64 vector base | 2 |
| VLD20 | 2 |
| VLD21 | 2 |
| VLD40 | 2 |
| VLD41 | 2 |
| VLD42 | 2 |
| VLD43 | 2 |
| VST20 | 2 |
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
