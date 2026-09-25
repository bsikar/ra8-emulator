//! Tests for src/core/memmap.zig.
const std = @import("std");
const ra8 = @import("ra8");
const mod = ra8.core.memmap;

const dwt = mod.dwt;
const nvic = mod.nvic;
const ppb_base = mod.ppb_base;
const ppb_size = mod.ppb_size;
const ram = mod.ram;
const scb = mod.scb;
const syst = mod.syst;
test "every named PPB register falls inside the PPB window" {
    inline for (.{ scb, syst, nvic, dwt }) |block| {
        inline for (@typeInfo(block).@"struct".decls) |decl| {
            const address = @field(block, decl.name);
            try std.testing.expect(address >= ppb_base);
            try std.testing.expect(address < ppb_base + ppb_size);
        }
    }
}

test "the PPB does not overlap the peripheral window" {
    try std.testing.expect(ppb_base > 0x4000_0000 + 0x1000_0000);
}

test "regions are ordered, non-overlapping and page aligned" {
    var previous_end: u64 = 0;
    for (ram) |region| {
        try std.testing.expect(region.base >= previous_end);
        try std.testing.expectEqual(@as(u32, 0), region.base % 0x1000);
        try std.testing.expectEqual(@as(u32, 0), region.size % 0x1000);
        previous_end = region.end();
    }
}
