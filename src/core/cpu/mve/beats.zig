//! Beat-wise execution of an MVE instruction (RA8EMU-107): the byte
//! lanes it writes are the VPT element mask cut down to the beats EPSR.ECI
//! says are still to run, and when it retires VPT advances over the beats
//! that ran and ECI moves on (B0 done becomes A0). In an IT block the IT
//! byte is IT state and every beat runs.
const eci = @import("eci.zig");
const vpt = @import("vpt.zig");
const Vpr = @import("predicate.zig").Vpr;

/// The byte lanes of the beats still to run.
pub fn pending(it: u8) u16 {
    return eci.beatMask(eci.fromIt(it));
}

/// The byte lanes a predicated instruction writes.
pub fn mask(vpr: Vpr, it: u8) u16 {
    return vpt.elementMask(vpr) & pending(it);
}

/// VPR and the IT byte once the instruction retires.
pub const Retired = struct { vpr: Vpr, it: u8 };

pub fn retire(vpr: Vpr, it: u8) Retired {
    return .{ .vpr = vpt.advanceBeats(vpr, pending(it)), .it = eci.next(it) };
}
