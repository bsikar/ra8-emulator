//! The emulated RA8D2 address space.
//!
//! Ported from inc/emu_memmap.h. The regions are silicon facts, so they are
//! constants here, not options.
const std = @import("std");

pub const Region = struct {
    name: []const u8,
    base: u32,
    size: u32,
    perms: Perms,

    pub const Perms = packed struct {
        read: bool = true,
        write: bool = true,
        exec: bool = true,
    };

    pub fn end(self: Region) u64 {
        return @as(u64, self.base) + self.size;
    }
};

pub const dtcm_base: u32 = 0x2000_0000;
pub const dtcm_end: u32 = 0x2001_0000;
pub const sram_base: u32 = 0x2200_0000;
pub const sram_end: u32 = 0x2210_0000;
pub const sdram_base: u32 = 0x6800_0000;
pub const sdram_end: u32 = 0x6C00_0000;
pub const ns_sdram_base: u32 = 0x7800_0000;

/// RAM and flash-like regions the loader maps before an image is streamed in.
pub const ram = [_]Region{
    .{ .name = "DTCM", .base = dtcm_base, .size = dtcm_end - dtcm_base, .perms = .{} },
    .{ .name = "SRAM", .base = sram_base, .size = sram_end - sram_base, .perms = .{} },
    .{ .name = "SDRAM", .base = sdram_base, .size = sdram_end - sdram_base, .perms = .{} },
    .{ .name = "NS SDRAM", .base = ns_sdram_base, .size = sdram_end - sdram_base, .perms = .{} },
};

test "regions are ordered, non-overlapping and page aligned" {
    var previous_end: u64 = 0;
    for (ram) |region| {
        try std.testing.expect(region.base >= previous_end);
        try std.testing.expectEqual(@as(u32, 0), region.base % 0x1000);
        try std.testing.expectEqual(@as(u32, 0), region.size % 0x1000);
        previous_end = region.end();
    }
}
