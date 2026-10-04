//! An ELF image streamed into guest memory, whichever backend holds it
//! (RA8EMU-539). This is the map-and-write half of Engine.loadImage, so a
//! `--cpu zig` run can load its image into the core's own store with no
//! engine open; the engine keeps its long-shift hook on top.
//!
//! The pages are merged before any is mapped (src/core/pages.zig): segments
//! of one image share pages, and a page already backed is refused.
const elf = @import("../../elf.zig");
const pages = @import("../../pages.zig");
const board_ram = @import("../../board_ram.zig");
const option_window = @import("../../../periph/mram/mram_window.zig");
const Guest = @import("guest.zig").Guest;

pub const Error = error{ MapFailed, WriteFailed };

/// Map the pages `image` needs that board RAM and the option window do not
/// already back, then write every PT_LOAD segment to its load address.
/// Returns the bytes written; an image that writes nothing is refused.
pub fn image(memory: Guest, loaded: elf.Image) Error!u32 {
    const needed = pages.forImage(loaded) catch return Error.MapFailed;
    for (needed.items()) |range| {
        if (board_ram.covers(range.base, range.size())) continue;
        if (option_window.claim(memory, range.base, range.size())) continue;
        memory.map(range.base, range.size()) catch return Error.MapFailed;
    }
    var written: u32 = 0;
    var index: u16 = 0;
    while (index < loaded.segmentCount()) : (index += 1) {
        const segment = loaded.loadSegment(index) orelse continue;
        memory.write(segment.paddr, segment.bytes) catch return Error.WriteFailed;
        written += @intCast(segment.bytes.len);
    }
    if (written == 0) return Error.WriteFailed;
    return written;
}
