//! Distinct 4 KiB backing pages accessed, including all-zero writes.
const std = @import("std");

const memmap = @import("../../memmap.zig");

pub const Tracker = struct {
    pub const sram_capacity = memmap.sram_end - memmap.sram_base;
    valid: bool = true,
    sram_base: u32 = memmap.sram_base,
    sdram_base: u32 = memmap.sdram_base,
    sram: std.StaticBitSet(sram_capacity / 4096) = .empty,
    sdram: std.StaticBitSet(128 * 1024 * 1024 / 4096) = .empty,
    pub fn invalidate(self: *Tracker) void {
        if (self.valid) {
            self.* = .{
                .valid = false,
                .sram_base = self.sram_base,
                .sdram_base = self.sdram_base,
            };
        }
    }
    pub fn note(self: *Tracker, base: u32, offset: usize, len: usize) void {
        if (!self.valid or len == 0) return;
        if (base == self.sram_base) mark(&self.sram, offset, len);
        if (base == self.sdram_base) mark(&self.sdram, offset, len);
    }
    fn mark(bits: anytype, offset: usize, len: usize) void {
        const end = @min((offset + len - 1) / 4096 + 1, bits.capacity());
        var page = offset / 4096;
        while (page < end) : (page += 1) {
            bits.set(page);
        }
    }
};
