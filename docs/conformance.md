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
