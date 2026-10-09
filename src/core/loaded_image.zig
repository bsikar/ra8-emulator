//! A firmware image as the chip takes it: the bytes each load segment
//! writes, the pages they need mapped, and where the vector table sits
//! (RA8EMU-1039, ADR 0004). The chip never parses an image format; the
//! board's loader reads ELF and fills this value, and boot, CPU1 bring-up
//! and the undefined-instruction sweep read only it.

/// Program-header flag for an executable segment.
pub const pf_x: u32 = 1;

pub const Segment = struct {
    vaddr: u32,
    paddr: u32,
    flags: u32,
    bytes: []const u8,
    memsz: u32,

    pub fn executable(self: Segment) bool {
        return (self.flags & pf_x) != 0;
    }
};

/// A whole number of pages, from `base` up to but not including `end`.
/// `end` is 64-bit so a range reaching the top of the address space is still
/// expressible; `base` is where a map starts and stays 32-bit.
pub const Range = struct {
    base: u32,
    end: u64,

    pub fn size(self: Range) u32 {
        return @intCast(self.end - self.base);
    }
};

/// Every slice points into storage the loader owns.
pub const Image = struct {
    /// The load segments with file bytes, in program-header order.
    segments: []const Segment,
    /// The merged page ranges those segments need mapped.
    maps: []const Range,
    /// The segment holding a valid stack pointer and Thumb reset vector.
    vector_base: ?u32,
};
