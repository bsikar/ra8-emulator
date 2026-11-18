//! An ELF image streamed into guest memory (RA8EMU-539, RA8EMU-1343).
//!
//! Pages outside the machine's declared regions and option window are mapped
//! only when the machine's `MemoryMap` allows extra pages; otherwise an
//! out-of-range load segment is refused with `Error.MapFailed`. Segment bytes
//! land through `Guest.program` so read-only flash regions can be populated at
//! load time while guest stores to flash fault at run time.
const Guest = @import("guest/guest.zig").Guest;
const loaded_image = @import("../../loaded_image.zig");
const option_window = @import("../../../periph/mram/window.zig");

pub const Error = error{ MapFailed, WriteFailed };

const page_bytes: u32 = 0x1000;

pub fn image(memory: Guest, loaded: loaded_image.Image) Error!u32 {
    try mapRanges(memory, loaded.maps);
    var written: u32 = 0;
    for (loaded.segments) |segment| {
        memory.program(segment.paddr, segment.bytes) catch return Error.WriteFailed;
        written += @intCast(segment.bytes.len);
    }
    if (written == 0) return Error.WriteFailed;
    return written;
}

fn mapRanges(memory: Guest, ranges: []const loaded_image.Range) Error!void {
    for (ranges) |range| {
        if (memory.backed(range.base, range.size())) continue;
        if (memory.allowsExtraPages() and option_window.claim(memory, range.base, range.size())) continue;
        if (!memory.allowsExtraPages()) return Error.MapFailed;
        try mapPages(memory, range);
    }
}

fn mapPages(memory: Guest, range: loaded_image.Range) Error!void {
    var at: u64 = range.base;
    const end: u64 = range.base + range.size();
    while (at < end) : (at += page_bytes) {
        if (memory.backed(@intCast(at), page_bytes)) continue;
        memory.map(@intCast(at), page_bytes) catch return Error.MapFailed;
    }
}
