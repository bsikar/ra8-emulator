//! Give the Zig core's engine the Private Peripheral Bus state the oracle's
//! board wiring set up at boot, such as DWT_CTRL.NUMCOMP. Without it the Zig
//! side reads zero where Unicorn reads the wired value, and lockstep reports
//! that as the first divergence of every image that looks.
//!
//! The copy goes a page at a time; a page either engine cannot reach is
//! skipped rather than failing the run, since nothing there can differ.
const memmap = @import("../../memmap.zig");
const engine = @import("../../engine.zig");

pub const page: u32 = 0x1000;

/// Copy the PPB from `theirs` into `mine`. Returns how many pages were copied.
pub fn ppb(mine: engine.Engine, theirs: engine.Engine) u32 {
    var bytes: [page]u8 = undefined;
    var copied: u32 = 0;
    var at: u32 = memmap.ppb_base;
    while (at - memmap.ppb_base < memmap.ppb_size) : (at += page) {
        theirs.read(at, &bytes) catch continue;
        mine.write(at, &bytes) catch continue;
        copied += 1;
    }
    return copied;
}
