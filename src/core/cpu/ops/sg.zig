//! SG (T1, 0xE97F 0xE97F), the Secure Gateway at a Non-secure callable entry
//! point (RA8EMU-357).
//!
//! Following the Armv8-M SG pseudocode and the fetch-time security check:
//!   * in Secure state SG is a NOP;
//!   * in Non-secure state, fetched from Non-secure memory, it is a NOP too;
//!   * in Non-secure state, fetched from Non-secure callable memory, the core
//!     becomes Secure: the banked registers swap through Banked.switchTo and
//!     LR bit 0 is cleared, so a BXNS LR at the end of the Secure function
//!     returns to Non-secure state;
//!   * in Non-secure state, fetched from Secure memory that is not callable,
//!     it is a SecureFault with SFSR.INVEP.
//!
//! The attribution comes from Cpu.attribution; with none set every address
//! is Secure, so the Non-secure cases only arise once a board supplies one.
const op = @import("../op.zig");
const attribution = @import("../attribution.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;

/// Both halfwords of SG.
pub const encoding: u16 = 0xE97F;

pub const group: op.Group = .{ .name = "sg", .decode = decode, .oracle = false };

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4 or instr.hw1 != encoding or instr.hw2 != encoding) return null;
    return gateway;
}

fn gateway(cpu: *Cpu, instr: Instr) op.Error!void {
    if (cpu.banked.current == .secure) return;
    switch (attribution.state(cpu.attribution, instr.address)) {
        .non_secure => {},
        .callable => {
            cpu.banked.switchTo(&cpu.regs, .secure);
            cpu.regs.lr &= ~@as(u32, 1);
        },
        .secure => return error.InvalidEntry,
    }
}
