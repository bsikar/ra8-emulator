//! Where a parsed `.ra8app` lands in a module region, and the copy that puts
//! it there (RA8EMU-54).
//!
//! A ThreadX module runs from one Non-Secure region: its code first, then its
//! data, each starting on a 32-byte boundary because that is the Armv8-M MPU
//! granule a module's region is fenced with. plan() works out the addresses
//! without touching memory, so a caller can refuse a module that does not fit
//! before any byte moves; load() then copies code and data through any memory
//! that has `write(address, []const u8) !void`, which keeps it the same on both
//! engine backends. The entry address carries the Thumb bit, ready for a
//! branch or an exception return.
const std = @import("std");

/// A module as the chip places it. The board's `.ra8app` reader fills it;
/// the chip never parses the app format.
pub const Module = struct {
    code: []const u8,
    data: []const u8,
    /// Offset of the entry point from the start of the code.
    entry_offset: u32,
};

/// The Armv8-M MPU region granule.
pub const granule: u32 = 32;

pub const Error = error{
    /// The region base is not on a granule boundary.
    Misaligned,
    /// Code and data do not fit in the region.
    TooBig,
};

pub const Region = struct {
    base: u32,
    size: u32,
};

pub const Placement = struct {
    code_base: u32,
    data_base: u32,
    /// The first byte past the data, rounded up to the granule.
    end: u32,
    /// Code base plus the entry offset, with the Thumb bit set.
    entry: u32,
};

fn roundUp(value: u64) u64 {
    return std.mem.alignForward(u64, value, granule);
}

/// The addresses a module would take in `region`, or why it cannot go there.
pub fn plan(module: Module, region: Region) Error!Placement {
    if (region.base % granule != 0) return Error.Misaligned;
    const base: u64 = region.base;
    const data_base = roundUp(base + module.code.len);
    const end = roundUp(data_base + module.data.len);
    if (end - base > region.size) return Error.TooBig;
    if (end > std.math.maxInt(u32)) return Error.TooBig;
    return .{
        .code_base = region.base,
        .data_base = @intCast(data_base),
        .end = @intCast(end),
        .entry = (region.base + module.entry_offset) | 1,
    };
}

/// Copy the module's code and data to where `placement` says.
pub fn load(memory: anytype, module: Module, placement: Placement) !void {
    try memory.write(placement.code_base, module.code);
    if (module.data.len != 0) try memory.write(placement.data_base, module.data);
}
