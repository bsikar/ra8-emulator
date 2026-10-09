//! Barriers: DSB, DMB and ISB (T1), any option.
//!
//! The Zig core runs one access at a time, in program order, and fetches each
//! instruction fresh from the bus, so every barrier is already satisfied by
//! the time it runs: none of them change state. SSBB and PSSBB are DSB with
//! options 0b0000 and 0b0100 and come along with it. A second core sharing
//! memory steps in turn with this one (RA8EMU-14 proves exclusives across
//! the two), which keeps that true there as well.
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;

pub const encodings = struct {
    pub const hw1: u16 = 0xF3BF;
    /// hw2 with the 4-bit option masked off.
    pub const option_mask: u16 = 0xFFF0;
    pub const dsb: u16 = 0x8F40;
    pub const dmb: u16 = 0x8F50;
    pub const isb: u16 = 0x8F60;
};

pub const group: op.Group = .{ .name = "barrier", .decode = decode };

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4 or instr.hw1 != encodings.hw1) return null;
    return switch (instr.hw2 & encodings.option_mask) {
        encodings.dsb, encodings.dmb, encodings.isb => satisfied,
        else => null,
    };
}

fn satisfied(cpu: *Cpu, instr: Instr) op.Error!void {
    _ = cpu;
    _ = instr;
}
