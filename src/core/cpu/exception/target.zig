//! Which Security state an exception is taken to (RA8EMU-168).
//!
//! From Secure, an interrupt whose NVIC_ITNS bit is set is Non-secure and
//! every other exception stays Secure. From Non-secure, SecureFault is
//! always Secure, and HardFault, NMI and BusFault are Secure unless
//! AIRCR.BFHFNMINS hands them to Non-secure; interrupts stay Non-secure
//! (ITNS clear on an interrupt pended from Non-secure is not modelled).
//! SysTick or PendSV pended in the Non-secure copy goes to Non-secure
//! (RA8EMU-438); one pended in the Secure copy keeps the rule above until
//! ICSR is wired through the bank split (RA8EMU-365).
const memmap = @import("../../memmap.zig");
const Cpu = @import("../cpu.zig").Cpu;

/// AIRCR.BFHFNMINS.
pub const bfhfnmins: u32 = 1 << 13;

/// NVIC_ITNS0; one bit per interrupt, 32 to a word. A bus with no NVIC
/// behind it reads zero, so every interrupt stays Secure.
pub const itns: u32 = 0xE000_E380;

pub fn secure(cpu: *const Cpu, number: u9) bool {
    if (cpu.entering_non_secure and (number == 14 or number == 15)) return false;
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
