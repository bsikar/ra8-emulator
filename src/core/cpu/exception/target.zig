//! Which Security state an exception is taken to (RA8EMU-168).
//!
//! From Secure every exception stays Secure here. From Non-secure,
//! SecureFault is always Secure, and HardFault, NMI and BusFault are Secure
//! unless AIRCR.BFHFNMINS hands them to Non-secure. The banked exceptions
//! and interrupts stay in the running state: ITNS routing and a banked
//! exception pended by the other state are not modelled yet.
const memmap = @import("../../memmap.zig");
const Cpu = @import("../cpu.zig").Cpu;

/// AIRCR.BFHFNMINS.
pub const bfhfnmins: u32 = 1 << 13;

pub fn secure(cpu: *const Cpu, number: u9) bool {
    if (cpu.banked.current == .secure) return true;
    return switch (number) {
        7 => true,
        2, 3, 5 => blk: {
            const aircr = cpu.bus.readWord(memmap.scb.aircr) catch 0;
            break :blk aircr & bfhfnmins == 0;
        },
        else => false,
    };
}
