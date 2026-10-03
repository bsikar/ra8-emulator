//! What step() does with an instruction run while EPSR.ECI/ICI is nonzero
//! (RA8EMU-453), as the Arm ARM (DDI0553) and QEMU's translate.c have it:
//! a beat-wise MVE instruction honours ECI itself, a load/store multiple
//! restarts from the start with ICI cleared (the IMPDEF choice QEMU makes),
//! LE, LETP and BKPT leave it, and anything else takes INVSTATE before it
//! runs. A reserved ECI value faults a beat-wise instruction too
//! (RA8EMU-452).
const op = @import("op.zig");
const Itstate = @import("it_state.zig").Itstate;
const eci = @import("mve/eci.zig");

pub const Action = enum { run, fault, restart };

/// True when the IT byte holds ECI/ICI: the low nibble clear, the high one
/// set. A set low nibble is an open IT block.
pub fn pending(it: Itstate) bool {
    return it != 0 and it & 0xF == 0;
}

pub fn action(it: Itstate, use: op.Eci) Action {
    if (!pending(it)) return .run;
    return switch (use) {
        .refuses => .fault,
        .restarts => .restart,
        .beat_wise => if (eci.fromIt(it) == .reserved) .fault else .run,
        .keeps => .run,
    };
}
