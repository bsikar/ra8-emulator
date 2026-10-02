//! USAD8 and USADA8 (T1): the sum of the four absolute byte differences of
//! Rn and Rm, plus Ra for USADA8. Ra = 1111 selects USAD8.
//!
//! Left unclaimed: SP or PC in Rd, Rn or Rm, and Ra = SP (UNPREDICTABLE).
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;

pub const encodings = struct {
    /// hw1 with Rn ([3:0]) masked out.
    pub const mask: u16 = 0xFFF0;
    pub const usad8: u16 = 0xFB70;
    /// hw2[7:4] must be zero.
    pub const hw2_op_mask: u16 = 0x00F0;
    /// Ra value that means "no accumulator".
    pub const no_ra: u4 = 15;
};

pub const group: op.Group = .{ .name = "usad8", .decode = decode };

pub const Fields = struct {
    rn: u4,
    ra: u4,
    rd: u4,
    rm: u4,

    pub fn of(instr: Instr) ?Fields {
        if (instr.size != 4 or instr.hw1 & encodings.mask != encodings.usad8) return null;
        if (instr.hw2 & encodings.hw2_op_mask != 0) return null;
        return .{
            .rn = @intCast(instr.hw1 & 0xF),
            .ra = @intCast(instr.hw2 >> 12),
            .rd = @intCast((instr.hw2 >> 8) & 0xF),
            .rm = @intCast(instr.hw2 & 0xF),
        };
    }
};

fn spOrPc(n: u4) bool {
    return n == 13 or n == 15;
}

fn decode(instr: Instr) ?op.Exec {
    const f = Fields.of(instr) orelse return null;
    if (spOrPc(f.rd) or spOrPc(f.rn) or spOrPc(f.rm) or f.ra == 13) return null;
    return exec;
}

/// Sum of |Rn.byte[i] - Rm.byte[i]| over the four bytes, plus `acc`, mod 2^32.
pub fn result(rn: u32, rm: u32, acc: u32) u32 {
    var sum: u32 = acc;
    for (0..4) |k| {
        const shift: u5 = @intCast(k * 8);
        const a: u8 = @truncate(rn >> shift);
        const b: u8 = @truncate(rm >> shift);
        sum +%= if (a > b) a - b else b - a;
    }
    return sum;
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = Fields.of(instr).?;
    const acc: u32 = if (f.ra == encodings.no_ra) 0 else cpu.regs.get(f.ra);
    cpu.regs.set(f.rd, result(cpu.regs.get(f.rn), cpu.regs.get(f.rm), acc));
}
