//! What a run asked for on top of the machine: real-time pacing against the
//! host clock (RA8EMU-181) and what ends a `--run-for` run early
//! (RA8EMU-186). The chip's `clocks.Time` holds machine time only; this sits
//! beside it on the board until the session run loop takes it (RA8EMU-1047).
const pacing = @import("../periph/time/pacing.zig");
const soak = @import("../periph/time/soak.zig");

pub const RunPolicy = struct {
    pacing: ?pacing.Pacing = null,
    soak: soak.Soak = .{},
};
