//! Conformance vectors for the decode group `fp_system` (RA8EMU-278):
//! VCMP and VCMPE (T1 register, T2 against +0.0) in half, single and
//! double precision, and the VMRS/VMSR transfers. Expected values are
//! worked from the Arm ARM (DDI0553): compares write FPSCR.NZCV as 1000
//! less, 0110 equal (+0 equals -0), 0010 greater, 0011 unordered; a
//! signalling NaN raises IOC, and VCMPE raises it for a quiet NaN too.
//! VMRS APSR_nzcv copies NZCV into the APSR and keeps the rest of xPSR;
//! VMSR FPSCR keeps only implemented bits (0xFFCF_009F); FPSCR_nzcvqc
//! moves bits 31:27; VPR writes drop the reserved top byte; P0 moves
//! VPR[15:0]; FPCXT is UNDEFINED from Non-secure, VMSR FPCXT_S loads
//! CONTROL.SFPA from bit 31 and FPSCR from bits 27:0, and VMRS FPCXT_S
//! returns SFPA:FPSCR[27:0], then loads FPSCR from FPDSCR and clears SFPA.
//! SP as Rt, PC for VMSR and the MVE registers, VCMP against zero with a
//! non-zero Vm, D16 and up, other register fields and the 16-bit space
//! are left unclaimed. Only the group's own decode runs here.
const defs = @import("system_types.zig");

const bad = defs.bad;
const V = defs.V;
const vec = defs.vec;

const vector = defs.vector;
pub const fpscr_reset = defs.fpscr_reset;
pub const r1_in = defs.r1_in;
pub const xpsr_in = defs.xpsr_in;
pub const In = defs.In;
pub const Fault = defs.Fault;
pub const Out = defs.Out;
pub const none = defs.none;

pub const all = compare ++ transfer ++ context ++ unclaimed;

const compare_01 = @import("system_compare_01.zig");

const compare = compare_01.values;

const transfer_01 = @import("system_transfer_01.zig");

const transfer = transfer_01.values;

const context = [_]V{
    vec(
        "vmsr fpcxt_s, r1 loads sfpa and fpscr",
        .{ .hw1 = 0xEEEF, .hw2 = 0x1A10, .r1 = 0x8004_0010 },
        .{ .r1 = 0x8004_0010, .fpscr = 0x0004_0010, .sfpa = true },
    ),
    vec(
        "vmrs r1, fpcxt_s saves then resets",
        .{ .hw1 = 0xEEFF, .hw2 = 0x1A10, .fpscr = 0x6004_0001, .sfpa = true },
        .{ .r1 = 0x8004_0001 },
    ),
    vec(
        "vmrs fpcxt_s from non-secure is undefined",
        .{ .hw1 = 0xEEFF, .hw2 = 0x1A10, .secure = false },
        .{ .fault = .undefined_instr },
    ),
    vec(
        "vmsr fpcxt_ns from non-secure is undefined",
        .{ .hw1 = 0xEEEE, .hw2 = 0x1A10, .secure = false },
        .{ .fault = .undefined_instr },
    ),
};

const unclaimed = [_]V{
    bad("vmrs sp, fpscr is unclaimed", 0xEEF1, 0xDA10),
    bad("vmsr fpscr, pc is unclaimed", 0xEEE1, 0xFA10),
    bad("vmrs pc, vpr is unclaimed", 0xEEFC, 0xFA10),
    bad("vmsr p0, sp is unclaimed", 0xEEED, 0xDA10),
    bad("register field 0011 is unclaimed", 0xEEF3, 0x1A10),
    bad("compare with zero and a non-zero vm is unclaimed", 0xEEB5, 0x0A41),
    bad("vcmp.f64 d16, d1 is unclaimed", 0xEEF4, 0x0B41),
    bad("vcmp with hw2 bit 4 set is unclaimed", 0xEEB4, 0x0A50),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEEF1, .hw2 = 0x1A10, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
