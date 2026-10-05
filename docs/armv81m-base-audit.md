# Armv8.1-M base additions: Zig core audit

Every instruction Armv8.1-M (DDI0553) adds outside MVE, and where the Zig
core stands on it. A row with a test is executed by the named op group
under src/core/cpu/ops/; a row without one names the open ticket that
covers the gap. MVE has its own coverage in conformance.md and its own
tickets under RA8EMU-8.

Audited for RA8EMU-258.

| Instruction(s) | Zig op group | Test | Ticket |
|---|---|---|---|
| CLRM | clrm.zig | tests/core/cpu/ops/clrm_test.zig | RA8EMU-260 (done) |
| VSCCLRM | vscclrm.zig | tests/core/cpu/ops/vscclrm_test.zig | RA8EMU-259 (veneer run waits on RA8EMU-293) |
| CSEL, CSINC, CSINV, CSNEG, and the CSET, CSETM, CINC, CINV, CNEG aliases | csel.zig (shares src/core/csel.zig) | tests/core/cpu/ops/csel_test.zig | RA8EMU-250 (done) |
| LSLL, LSRL, ASRL by immediate | long_shift.zig | tests/core/cpu/ops/long_shift_test.zig | RA8EMU-138 (done) |
| LSLL, ASRL by register | none | none | RA8EMU-136 |
| UQSHL, SQSHL, URSHR, SRSHR, UQRSHL, SQRSHR | none | none | RA8EMU-137 |
| UQSHLL, URSHRL, SRSHRL, SQSHLL, UQRSHLL, SQRSHRL | none | none | RA8EMU-139 |
| DLS, WLS, LE | src/core/cpu/ops/lob.zig on the Zig core; src/core/lob.zig decodes | tests/core/lob_test.zig, tests/core/cpu/ops/lob_test.zig | RA8EMU-239 |
| DLSTP, WLSTP, LETP, LCTP, VCTP | none | none | RA8EMU-24 |
| BF, BFX, BFL, BFLX, BFCSEL | none | none | RA8EMU-299 |
| PAC, PACBTI, PACG, AUT, AUTG, BXAUT | none | none | RA8EMU-244 |
| BTI and the EPSR.B landing-pad check | none | none | RA8EMU-245 |
| CONTROL.PAC_EN, BTI_EN, UPAC_EN, UBTI_EN | none | none | RA8EMU-246 |
| VMRS, VMSR for VPR and P0 | fp_system.zig | tests/core/cpu/ops/fp_system_test.zig | none |
| VMRS, VMSR for FPCXT_NS, FPCXT_S, FPSCR_nzcvqc | none | none | RA8EMU-295 |
| VLDR, VSTR system-register forms | none | none | RA8EMU-298 |
| VLLDM, VLSTM (T1, and the T2 forms) | none | none | RA8EMU-297 |
| ESB, CSDB, unallocated hints | hint.zig claims 0 to 4 only | tests/core/cpu/ops/hint_test.zig | RA8EMU-296 |

Gaps the table does not show per row: the Zig core has no current
Security state yet, so the Secure-only and Non-secure UNDEFINED checks
these instructions carry are not modelled, and NOCP is RA8EMU-145.
