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
    // them out; src/core/idle.zig needs the WHOLE architectural state,
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
};
