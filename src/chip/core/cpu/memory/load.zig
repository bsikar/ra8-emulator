//! An ELF image streamed into guest memory, whichever backend holds it
//! (RA8EMU-539). This is the map-and-write half of Engine.loadImage, so a
//! `--cpu zig` run can load its image into the core's own store with no
//! engine open; the engine keeps its long-shift hook on top.
//!
//! The board's loader merges the pages before any is mapped: segments of
//! one image share pages, and a page already backed is refused.
const loaded_image = @import("../../loaded_image.zig");
const option_window = @import("../../../periph/mram/window.zig");
const Guest = @import("guest/guest.zig").Guest;

pub const Error = error{ MapFailed, WriteFailed };

/// The page size the CPU model maps at, the board's loader merges at
/// (image/pages.zig) and the option window erases at.
const page_bytes: u32 = 0x1000;

/// Map the pages `image` needs that board RAM and the option window do not
/// already back, then write every PT_LOAD segment to its load address.
/// Returns the bytes written; an image that writes nothing is refused.
pub fn image(memory: Guest, loaded: loaded_image.Image) Error!u32 {
    for (loaded.maps) |range| {
        if (memory.backed(range.base, range.size())) continue;
        if (option_window.claim(memory, range.base, range.size())) continue;
        // A replacement image shares pages with the one it replaces, and a
        // page the store already holds is refused, so map one page at a
        // time and keep what is already there (RA8EMU-959). The board's
        // page merge (image/pages.zig) hands whole-page ranges over.
        var at: u64 = range.base;
        const end: u64 = range.base + range.size();
        while (at < end) : (at += page_bytes) {
            if (memory.backed(@intCast(at), page_bytes)) continue;
            memory.map(@intCast(at), page_bytes) catch return Error.MapFailed;
        }
    }
    var written: u32 = 0;
    for (loaded.segments) |segment| {
        memory.write(segment.paddr, segment.bytes) catch return Error.WriteFailed;
        written += @intCast(segment.bytes.len);
    }
    if (written == 0) return Error.WriteFailed;
    return written;
}
