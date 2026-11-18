//! The lines of memory that hold formed blocks (RA8EMU-407, RA8EMU-1343).
//!
//! BlockCache marks the 64-byte lines a block covers when it forms one. A
//! store through the core's bus that touches a marked line clears those
//! marks and widens a dirty range of lines; BlockCache drops every block
//! overlapping that range before it hands out the next entry. Tracked code
//! ranges and their aliases come from the machine's `MemoryMap`, so an alias
//! write folds onto the same line indices as its canonical region.
const std = @import("std");

const memmap = @import("../memmap.zig");
const memory_map = @import("../machine/memory.zig");

pub const line_shift: u5 = 6;
pub const line_size: u32 = @as(u32, 1) << line_shift;

const dtcm_lines: usize = (memmap.dtcm_end - memmap.dtcm_base) >> line_shift;
const mram_lines: usize = (memmap.mram_end - memmap.mram_base) >> line_shift;
const sram_lines: usize = (memmap.sram_end - memmap.sram_base) >> line_shift;

/// Default RA8 tracked line count.
pub const lines: usize = dtcm_lines + mram_lines + sram_lines;
/// Capacity of `CodeLines.marks` (64K lines = 4 MiB of tracked code space).
pub const max_lines: usize = 65_536;
pub const max_ranges: usize = 24;

pub const Range = struct { base: u32, end: u32, first: usize };

pub const Layout = struct {
    ranges: [max_ranges]Range = @splat(.{ .base = 0, .end = 0, .first = 0 }),
    count: usize = 0,
    total_lines: usize = 0,

    /// Build tracked 64-byte line ranges from `map`, folding aliases onto
    /// their target region's `first` line index.
    pub fn fromMap(map: *const memory_map.MemoryMap) Layout {
        var out: Layout = .{};
        var region_first: [memory_map.max_regions]?usize = @splat(null);
        for (map.regions, 0..) |entry, idx| {
            if (!entry.track_code or entry.size < line_size) continue;
            const span: usize = entry.size >> line_shift;
            if (out.count >= max_ranges or out.total_lines + span > max_lines) continue;
            const end_u64 = entry.end();
            const end_u32: u32 = if (end_u64 > 0xFFFF_FFFF) 0xFFFF_FFFF else @intCast(end_u64);
            out.ranges[out.count] = .{ .base = entry.base, .end = end_u32, .first = out.total_lines };
            region_first[idx] = out.total_lines;
            out.count += 1;
            out.total_lines += span;
        }
        for (map.aliases) |alias| {
            if (out.count >= max_ranges) break;
            const target_idx = map.indexOf(alias.of) orelse continue;
            const first = region_first[target_idx] orelse continue;
            const end_u64 = alias.end();
            const end_u32: u32 = if (end_u64 > 0xFFFF_FFFF) 0xFFFF_FFFF else @intCast(end_u64);
            out.ranges[out.count] = .{ .base = alias.view, .end = end_u32, .first = first };
            out.count += 1;
        }
        return out;
    }

    pub fn line(self: *const Layout, address: u32) ?usize {
        for (self.ranges[0..self.count]) |range| {
            if (address >= range.base and address < range.end) {
                return range.first + ((address - range.base) >> line_shift);
            }
        }
        return null;
    }

    pub fn covers(self: *const Layout, start: u32, end: u32) bool {
        if (end <= start) return false;
        const first = self.line(start) orelse return false;
        const last = self.line(end - 1) orelse return false;
        return last >= first and last - first == ((end - 1) >> line_shift) - (start >> line_shift);
    }
};

pub const ra8_layout: Layout = Layout.fromMap(&memory_map.ra8);

/// Whether every line of [start, end) is tracked in the default RA8 layout.
pub fn covers(start: u32, end: u32) bool {
    return ra8_layout.covers(start, end);
}

/// The line holding `address` in the default RA8 layout, or null outside it.
pub fn line(address: u32) ?usize {
    return ra8_layout.line(address);
}

/// The caches one machine's writes reach, so writers that bypass a core's
/// bus drop blocks too (RA8EMU-409).
pub const Fanout = struct {
    layout: Layout = ra8_layout,
    caches: [2]?*CodeLines = .{ null, null },
    count: usize = 0,

    pub fn attach(self: *Fanout, cache: *CodeLines) error{TooManyCaches}!void {
        for (&self.caches) |*slot| if (slot.* == null) {
            if (!std.meta.eql(cache.layout, self.layout)) {
                cache.clear();
                cache.layout = self.layout;
            }
            slot.* = cache;
            self.count += 1;
            return;
        };
        return error.TooManyCaches;
    }

    pub fn detach(self: *Fanout, cache: *CodeLines) void {
        for (&self.caches) |*slot| if (slot.* == cache) {
            slot.* = null;
            self.count -= 1;
            return;
        };
    }

    /// A write of `len` bytes at `address` from anywhere.
    pub inline fn notify(self: *const Fanout, address: u32, len: usize) void {
        if (self.count == 0) return;
        for (self.caches) |slot| if (slot) |cache| cache.stored(address, len);
    }
};

pub const CodeLines = struct {
    layout: Layout = ra8_layout,
    marks: [(max_lines + 63) / 64]u64,
    /// Lines written since the last drop, inclusive; valid while `dirty`.
    dirty: bool,
    low: usize,
    high: usize,

    pub fn init(self: *CodeLines) void {
        self.layout = ra8_layout;
        self.clear();
    }

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
            const n = self.layout.line(@intCast(at)) orelse continue;
            self.marks[n >> 6] |= bit(n);
        }
    }

    pub fn marked(self: *const CodeLines, address: u32) bool {
        const n = self.layout.line(address) orelse return false;
        return self.marks[n >> 6] & bit(n) != 0;
    }

    /// A store of `len` bytes at `address`: any marked line it touches is
    /// cleared and joins the dirty range.
    pub fn stored(self: *CodeLines, address: u32, len: usize) void {
        const first = self.layout.line(address) orelse return;
        const last = self.layout.line(address +% @as(u32, @intCast(len -| 1))) orelse first;
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
