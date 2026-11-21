//! Himax HX6538 (WE2) fixed bit-28 IDAU map (`trustzone_cfg.c`).
//!
//! Opposite to RA8: below `0x6000_0000`, bit 28 set selects Secure aliases
//! (`0x1...` Code/ITCM/BootROM, `0x3...` DTCM/SRAM/QSPI, `0x5...` Secure
//! peripherals), while bit 28 clear selects Non-secure/SAU-controllable
//! windows (`0x0...`, `0x2...`, `0x4...`). Regions `1` and `3` permit SAU
//! Non-secure callable veneers (`SG`), region `5` stays strictly Secure, and
//! `0xE000_0000..0xFFFF_FFFF` is exempt for system and debug space.
const sau_attr = @import("../../../periph/sau/attribution.zig");

pub const alias_bit: u32 = 1 << 28;
pub const ext_base: u32 = 0x6000_0000;
pub const exempt_base: u32 = 0xE000_0000;

pub fn answer(address: u32) sau_attr.Idau {
    if (address >= exempt_base) return .{ .state = .non_secure, .exempt = true, .region = 7 };
    if (address >= ext_base) return .{ .state = .non_secure, .region = 6 };
    const region: u8 = @intCast(address >> 28);
    const state: sau_attr.State = switch (region) {
        1, 3 => .callable,
        5 => .secure,
        else => .non_secure,
    };
    return .{ .state = state, .region = region };
}

pub fn callbackFn(_: ?*const anyopaque, address: u32) sau_attr.Idau {
    return answer(address);
}
