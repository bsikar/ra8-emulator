//! Option-setting memory, read once the image is in place.
//!
//! The boot ROM reads OFS0 before the first instruction runs, so whoever
//! builds the chip reads it at the same point: after the image is loaded,
//! before the core starts. An address the image left unwritten reads as an
//! erased part. This is MCU flash behaviour, the same on any board.
const iwdt = @import("iwdt.zig");

pub const default_address = iwdt.ofs0.address;
/// RA8E1 Code Flash Option-Setting Memory `OFS0` address (`R01UH1129EJ0110` §6.2.1).
pub const ra8e1_address: u32 = 0x0300_A100;

/// Hand the image's OFS0 word at the default RA8 address to the watchdog.
pub fn apply(watchdog: *iwdt.Iwdt, core: anytype) void {
    applyAt(watchdog, core, default_address);
}

/// Hand the image's OFS0 word at `address` to the blocks it configures at reset.
pub fn applyAt(watchdog: *iwdt.Iwdt, core: anytype, address: u32) void {
    const word = core.readWord(address) catch iwdt.ofs0.erased;
    watchdog.applyOptionWord(word);
}

/// Select the machine's OFS0 address (`ra8e1` uses `0x0300_A100`) and apply it.
pub fn applyForMachine(watchdog: *iwdt.Iwdt, core: anytype, mem: anytype) void {
    const at = if (mem.resolvedPeripherals() == .ra8e1) ra8e1_address else default_address;
    applyAt(watchdog, core, at);
}
