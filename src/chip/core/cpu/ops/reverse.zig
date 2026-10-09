//! REV, REV16 and REVSH (T1): byte reversal of Rm into Rd. REV swaps all
//! four bytes, REV16 swaps the bytes within each halfword, and REVSH swaps
//! the low halfword's bytes and sign-extends the result. No flags change.
//! op 0b10 of the same space is unallocated on Armv8-M and stays unclaimed.
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;

pub const encodings = struct {
    pub const mask: u16 = 0xFF00;
    pub const reverse: u16 = 0xBA00;
};

pub const Kind = enum(u2) { rev, rev16, unallocated, revsh };

pub const group: op.Group = .{ .name = "reverse", .decode = decode };

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 2 or instr.hw1 & encodings.mask != encodings.reverse) return null;
    if (kindOf(instr.hw1) == .unallocated) return null;
    return run;
}

fn kindOf(hw1: u16) Kind {
    return @fromBackingInt(@intCast((hw1 >> 6) & 3));
}

/// `value` reversed the way `kind` says. `unallocated` returns it unchanged.
pub fn apply(kind: Kind, value: u32) u32 {
    return switch (kind) {
        .rev => @byteSwap(value),
        .rev16 => ((value & 0x00FF_00FF) << 8) | ((value >> 8) & 0x00FF_00FF),
        .revsh => @bitCast(@as(i32, @as(i16, @bitCast(@byteSwap(@as(u16, @truncate(value))))))),
        .unallocated => value,
    };
}

fn run(cpu: *Cpu, instr: Instr) op.Error!void {
    const rm: u4 = @intCast((instr.hw1 >> 3) & 7);
    const rd: u4 = @intCast(instr.hw1 & 7);
    cpu.regs.set(rd, apply(kindOf(instr.hw1), cpu.regs.get(rm)));
}
