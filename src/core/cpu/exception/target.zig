//! Which Security state an exception is taken to (RA8EMU-168).
//!
//! From Secure, an interrupt whose NVIC_ITNS bit is set is Non-secure and
//! every other exception stays Secure. From Non-secure, SecureFault is
//! always Secure, and HardFault, NMI and BusFault are Secure unless
//! AIRCR.BFHFNMINS hands them to Non-secure; interrupts stay Non-secure
//! (ITNS clear on an interrupt pended from Non-secure is not modelled).
//! PendSV is banked: the copy it was pended in decides (RA8EMU-439).
//! SysTick from the Non-secure copy goes Non-secure (RA8EMU-438); from the
//! shared word it keeps the rule above while one timer pends it there
//! (RA8EMU-154).
const memmap = @import("../../memmap.zig");
const Cpu = @import("../cpu.zig").Cpu;

/// AIRCR.BFHFNMINS.
pub const bfhfnmins: u32 = 1 << 13;

/// NVIC_ITNS0; one bit per interrupt, 32 to a word. A bus with no NVIC
/// behind it reads zero, so every interrupt stays Secure.
pub const itns: u32 = 0xE000_E380;

pub fn secure(cpu: *const Cpu, number: u9) bool {
    if (number == 14) return !cpu.entering_non_secure;
    if (cpu.entering_non_secure and number == 15) return false;
    if (cpu.banked.current == .secure) return number < 16 or !nonSecureIrq(cpu, number - 16);
    return switch (number) {
        7 => true,
        2, 3, 5 => blk: {
            const aircr = cpu.bus.readWord(memmap.scb.aircr) catch 0;
            break :blk aircr & bfhfnmins == 0;
        },
        else => false,
    };
}

fn nonSecureIrq(cpu: *const Cpu, irq: u9) bool {
    const word = cpu.bus.readWord(itns +% @as(u32, irq / 32) * 4) catch 0;
    return word >> @intCast(irq % 32) & 1 != 0;
}
