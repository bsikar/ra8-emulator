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
pub const ns_sdram_end: u32 = ns_sdram_base + (sdram_end - sdram_base);

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
    .{ .name = "NS SDRAM", .base = ns_sdram_base, .size = ns_sdram_end - ns_sdram_base, .perms = .{} },
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
};

/// The Arm v8-M cache maintenance window, the other half of the SCB the
/// firmware drives. CTR and CCSIDR report the geometry and are read-only;
/// CSSELR picks which cache CCSIDR describes; the rest are write-only
/// maintenance ports. Architectural, so constants like the rest of the PPB.
pub const cache = struct {
    pub const ctr: u32 = 0xE000_ED7C;
    pub const ccsidr: u32 = 0xE000_ED80;
    pub const csselr: u32 = 0xE000_ED84;
    pub const iciallu: u32 = 0xE000_EF50;
    pub const dcimvac: u32 = 0xE000_EF5C;
    pub const dcisw: u32 = 0xE000_EF60;
    pub const dccmvac: u32 = 0xE000_EF68;
    pub const dccimvac: u32 = 0xE000_EF70;
    pub const dccisw: u32 = 0xE000_EF74;
};

/// The SysTick block. Architectural on every Cortex-M, so these are constants
/// like the rest of the PPB.
pub const syst = struct {
    pub const csr: u32 = 0xE000_E010;
    pub const rvr: u32 = 0xE000_E014;
    pub const cvr: u32 = 0xE000_E018;
    pub const calib: u32 = 0xE000_E01C;
};

/// The NVIC's register file. Set and clear registers are separate on
/// hardware, and against a plain-RAM PPB both are just words: src/nvic.zig
/// folds the clear side into the set side at the chunk boundary.
pub const nvic = struct {
    pub const iser: u32 = 0xE000_E100;
    pub const icer: u32 = 0xE000_E180;
    pub const ispr: u32 = 0xE000_E200;
    pub const icpr: u32 = 0xE000_E280;
    pub const iabr: u32 = 0xE000_E300;
    pub const ipr: u32 = 0xE000_E400;
};

/// The Data Watchpoint and Trace unit. Only the free-running cycle counter and
/// its enable are named: that counter is the time base the firmware spins on
/// with interrupts masked, which is the whole reason the emulator models it.
pub const dwt = struct {
    pub const ctrl: u32 = 0xE000_1000;
    pub const cyccnt: u32 = 0xE000_1004;
};

/// A span of addresses, as a base and the first address past it.
pub const Window = struct {
    base: u32,
    end: u32,

    /// Whether `len` bytes at `at` lie wholly inside this window.
    pub fn holds(self: Window, at: u32, len: u32) bool {
        return at >= self.base and @as(u64, at) + len <= @as(u64, self.end);
    }
};

/// The RAM a bus master other than the CPU can reach: the on-chip SRAM and
/// the external SDRAM, through both its Secure and its Non-secure alias.
///
/// DTCM is deliberately not here. It is the core's own tightly coupled
/// memory, reached over the CPU's private port rather than over the fabric
/// the descriptor engines and the drawing engine issue on, so a ring or a
/// texture pointed into it is a programming bug on the bench as much as it
/// is here. The peripheral window is not here either, for the same reason it
/// never was: it is registers, not somewhere a frame may be read out of or
/// written into.
pub const master_ram = [_]Window{
    .{ .base = sram_base, .end = sram_end },
    .{ .base = sdram_base, .end = sdram_end },
    .{ .base = ns_sdram_base, .end = ns_sdram_end },
};

/// Whether a span of `len` bytes at `at` is somewhere a bus master may read
/// or write. A model that follows a pointer the firmware gave it asks this
/// first, because a half-built descriptor points anywhere.
pub fn masterHolds(at: u32, len: u32) bool {
    if (len == 0) return false;
    for (master_ram) |window| {
        if (window.holds(at, len)) return true;
    }
    return false;
}

/// The window an address sits in, or null when it sits in none. A model
/// that walks forward from a base it was handed (a scan-out down a
/// framebuffer, a walk along a ring) asks this instead of `masterHolds`,
/// because it needs to know where the room runs out, not only that the
/// first byte is in it.
pub fn masterWindow(at: u32) ?Window {
    for (master_ram) |window| {
        if (at >= window.base and at < window.end) return window;
    }
    return null;
}
