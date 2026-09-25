//! The emulated RA8D2 address space.
//!
//! The regions are silicon facts, so they are
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

/// The Cortex-M Private Peripheral Bus: SCB, NVIC, SysTick, MPU, SAU and the
/// debug block. The C emulator maps this as plain RAM rather than callback
/// MMIO, so a write lands and a read gives it back. Several of the registers
/// the firmware touches (VTOR, SHPRn, MPU_RBAR/RLAR) are read back by the very
/// code that wrote them, and that is the behaviour plain RAM gives for free.
pub const ppb_base: u32 = 0xE000_0000;
pub const ppb_size: u32 = 0x0010_0000;

/// RAM and flash-like regions the loader maps before an image is streamed in.
pub const ram = [_]Region{
    .{ .name = "DTCM", .base = dtcm_base, .size = dtcm_end - dtcm_base, .perms = .{} },
    .{ .name = "SRAM", .base = sram_base, .size = sram_end - sram_base, .perms = .{} },
    .{ .name = "SDRAM", .base = sdram_base, .size = sdram_end - sdram_base, .perms = .{} },
    .{ .name = "NS SDRAM", .base = ns_sdram_base, .size = sdram_end - sdram_base, .perms = .{} },
    .{ .name = "PPB", .base = ppb_base, .size = ppb_size, .perms = .{ .exec = false } },
};

/// Register addresses inside the PPB the rest of the emulator names. They are
/// architectural, so they are constants rather than options.
pub const scb = struct {
    pub const icsr: u32 = 0xE000_ED04;
    pub const vtor: u32 = 0xE000_ED08;
    pub const aircr: u32 = 0xE000_ED0C;
    pub const ccr: u32 = 0xE000_ED14;
    pub const shpr2: u32 = 0xE000_ED1C;
    pub const shpr3: u32 = 0xE000_ED20;
    pub const cfsr: u32 = 0xE000_ED28;
    pub const mmfar: u32 = 0xE000_ED34;
    pub const mpu_type: u32 = 0xE000_ED90;
    pub const mpu_ctrl: u32 = 0xE000_ED94;
    pub const demcr: u32 = 0xE000_EDFC;
    pub const syst_csr: u32 = 0xE000_E010;
};

test "every named PPB register falls inside the PPB window" {
    const fields = @typeInfo(scb).@"struct".decls;
    inline for (fields) |decl| {
        const address = @field(scb, decl.name);
        try std.testing.expect(address >= ppb_base);
        try std.testing.expect(address < ppb_base + ppb_size);
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
