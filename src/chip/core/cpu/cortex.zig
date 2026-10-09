//! The architectural registers the debugger, the report and the run loop
//! name. A plain enum: the Zig core indexes its own register file.

pub const Cortex = enum {
    pc,
    sp,
    lr,
    r0,
    r1,
    r2,
    // The rest of the caller-saved set, plus the two status registers:
    // exception entry stacks them and the controller reads them.
    r3,
    r12,
    xpsr,
    primask,
    // The Process stack pointer. A scheduler's handler reads it to find the
    // frame it has to save and writes it to name the thread it picked, so
    // exception entry and return both keep it current.
    psp,
    // The callee-saved half of the file, the Main stack pointer and the
    // three remaining words that mask or select interrupts. None of them is
    // an argument at a call boundary, which is why the dump above leaves
    // them out; src/chip/core/idle.zig needs the WHOLE architectural state,
    // because a loop that walks any one of these is making progress.
    r4,
    r5,
    r6,
    r7,
    r8,
    r9,
    r10,
    r11,
    msp,
    basepri,
    faultmask,
    control,
    fpscr,
    // The Armv8-M stack limits. Only the debugger names them here; no dump
    // or run loop reads them through this enum.
    msplim,
    psplim,
    // The FPv5 single-precision bank as raw bits, for the debugger's FPU
    // group. D[n] is S[2n+1]:S[2n], so the doubles need no names of their own.
    s0,
    s1,
    s2,
    s3,
    s4,
    s5,
    s6,
    s7,
    s8,
    s9,
    s10,
    s11,
    s12,
    s13,
    s14,
    s15,
    s16,
    s17,
    s18,
    s19,
    s20,
    s21,
    s22,
    s23,
    s24,
    s25,
    s26,
    s27,
    s28,
    s29,
    s30,
    s31,
    // MVE's predicate register (VPR: P0 and the two VPT masks), the one
    // piece of M85 vector state the FP bank does not already hold.
    vpr,
};
