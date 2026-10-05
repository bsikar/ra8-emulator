//! Which spans are the board's own RAM, so an image's segments are streamed
//! into a region rather than mapped on top of it (src/core/cpu/memory/load.zig)
//! and an idle loop's spin target can be told from code (src/core/idle.zig).
//!
//! The Non-secure aliases and the pages CPU0 and CPU1 share are the Zig
//! core's own store's rules (src/core/cpu/memory/store.zig).
const memmap = @import("memmap.zig");

/// The page size the board's regions are aligned to.
pub const page: usize = 0x1000;

/// Whether a span of `len` bytes at `base` is already one of the board's
/// regions. An image's own pages are mapped around what this covers, so a
/// segment landing in SRAM is streamed into the region rather than mapped
/// on top of it.
pub fn covers(base: u32, len: u32) bool {
    for (memmap.ram) |region| {
        if (base >= region.base and @as(u64, base) + len <= region.end()) return true;
    }
    return false;
}
