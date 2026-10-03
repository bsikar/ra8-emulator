//! The lines of memory that hold formed blocks (RA8EMU-407).
//!
//! BlockCache marks the 64-byte lines a block covers when it forms one. A
//! store through the core's bus that touches a marked line clears those
//! marks and widens a dirty range of lines; BlockCache drops every block
//! overlapping that range before it hands out the next entry. Only the
//! ranges code runs from are tracked: DTCM, MRAM and SRAM, with the
//! Non-secure SRAM and MRAM aliases folded onto the same lines.
const memmap = @import("../memmap.zig");

pub const line_shift: u5 = 6;
pub const line_size: u32 = @as(u32, 1) << line_shift;

const dtcm_lines: usize = (memmap.dtcm_end - memmap.dtcm_base) >> line_shift;
const mram_lines: usize = (memmap.mram_end - memmap.mram_base) >> line_shift;
const sram_lines: usize = (memmap.sram_end - memmap.sram_base) >> line_shift;

/// Every tracked line.
pub const lines: usize = dtcm_lines + mram_lines + sram_lines;

const Range = struct { base: u32, end: u32, first: usize };

const ranges = [_]Range{
    .{ .base = memmap.dtcm_base, .end = memmap.dtcm_end, .first = 0 },
    .{ .base = memmap.mram_base, .end = memmap.mram_end, .first = dtcm_lines },
    .{ .base = memmap.ns_mram_base, .end = memmap.ns_mram_end, .first = dtcm_lines },
    .{ .base = memmap.ns_mram_base, .end = memmap.ns_mram_end, .first = dtcm_lines },
    .{ .base = memmap.sram_base, .end = memmap.sram_end, .first = dtcm_lines + mram_lines },
    .{ .base = memmap.ns_sram_base, .end = memmap.ns_sram_end, .first = dtcm_lines + mram_lines },
};

/// Whether every line of [start, end) is tracked, so a write over it is
/// always reported and the block needs no re-check (RA8EMU-409).
pub fn covers(start: u32, end: u32) bool {
    if (end <= start) return false;
    const first = line(start) orelse return false;
    const last = line(end - 1) orelse return false;
    return last >= first and last - first == ((end - 1) >> line_shift) - (start >> line_shift);
}

/// The line holding `address`, or null outside the tracked ranges.
pub fn line(address: u32) ?usize {
    inline for (ranges) |range| {
        if (address >= range.base and address < range.end)
            return range.first + ((address - range.base) >> line_shift);
    }
    return null;
}

/// The caches every write reaches, so writers that bypass a core's bus (DMA,
/// the MRAM model, the debugger, module placement, the other core's direct
/// stores) drop blocks too (RA8EMU-409).
var watching: [4]?*CodeLines = .{ null, null, null, null };
var watchers: usize = 0;

pub fn watch(cache: *CodeLines) error{TooManyCaches}!void {
    for (&watching) |*slot| if (slot.* == null) {
        slot.* = cache;
        watchers += 1;
        return;
    };
    return error.TooManyCaches;
}

pub fn unwatch(cache: *CodeLines) void {
    for (&watching) |*slot| if (slot.* == cache) {
        slot.* = null;
        watchers -= 1;
        return;
    };
}

/// A write of `len` bytes at `address` from anywhere.
pub inline fn notify(address: u32, len: usize) void {
    if (watchers == 0) return;
    for (watching) |slot| if (slot) |cache| cache.stored(address, len);
}

pub const CodeLines = struct {
    marks: [(lines + 63) / 64]u64,
    /// Lines written since the last drop, inclusive; valid while `dirty`.
    dirty: bool,
    low: usize,
    high: usize,

    pub fn clear(self: *CodeLines) void {
        @memset(&self.marks, 0);
        self.dirty = false;
        self.low = 0;
        self.high = 0;
    }

    /// Mark the lines that [start, end) covers.
    pub fn mark(self: *CodeLines, start: u32, end: u32) void {
        var at: u64 = start & ~(line_size - 1);
        while (at < end) : (at += line_size) {
            const n = line(@intCast(at)) orelse continue;
            self.marks[n >> 6] |= bit(n);
        }
    }

    pub fn marked(self: *const CodeLines, address: u32) bool {
        const n = line(address) orelse return false;
        return self.marks[n >> 6] & bit(n) != 0;
    }

    /// A store of `len` bytes at `address`: any marked line it touches is
    /// cleared and joins the dirty range.
    pub fn stored(self: *CodeLines, address: u32, len: usize) void {
        const first = line(address) orelse return;
        const last = line(address +% @as(u32, @intCast(len -| 1))) orelse first;
        var hit = false;
        var n = first;
        while (n <= last) : (n += 1) {
            if (self.marks[n >> 6] & bit(n) == 0) continue;
            self.marks[n >> 6] &= ~bit(n);
            hit = true;
        }
        if (!hit) return;
        self.low = if (self.dirty) @min(self.low, first) else first;
        self.high = if (self.dirty) @max(self.high, last) else last;
        self.dirty = true;
    }

    fn bit(n: usize) u64 {
        return @as(u64, 1) << @intCast(n & 63);
    }
};
