//! The 32-bit multiplies with an optional accumulate (T2 and T1): MUL, MLA and
//! MLS. Rd = Rn * Rm, plus Ra for MLA and subtracted from Ra for MLS; only
//! the low 32 bits are kept. None of them touch the flags. MUL is MLA with
//! the Ra field set to PC.
//!
//! SP or PC in Rd, Rn or Rm is UNPREDICTABLE, as are Ra of SP and an MLS with
//! Ra of PC; all are left unclaimed.
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;

pub const encodings = struct {
    /// hw1 with Rn ([3:0]) masked out.
    pub const mask: u16 = 0xFFF0;
    pub const mla_mls: u16 = 0xFB00;
    /// hw2[7:4] picks MLA (0000) or MLS (0001).
    pub const hw2_op2: u16 = 0x00F0;
    pub const op2_mla: u16 = 0x0000;
    pub const op2_mls: u16 = 0x0010;
};

pub const group: op.Group = .{ .name = "mul_acc", .decode = decode };

pub const Kind = enum { mul, mla, mls };

pub const Fields = struct {
    kind: Kind,
    rn: u4,
    rm: u4,
    rd: u4,
    ra: u4,

    pub fn of(instr: Instr) ?Fields {
        if (instr.size != 4 or instr.hw1 & encodings.mask != encodings.mla_mls) return null;
        const ra: u4 = @intCast(instr.hw2 >> 12);
        const kind: Kind = switch (instr.hw2 & encodings.hw2_op2) {
            encodings.op2_mla => if (ra == 15) .mul else .mla,
            encodings.op2_mls => .mls,
            else => return null,
        };
        return .{
            .kind = kind,
            .rn = @intCast(instr.hw1 & 0xF),
            .rm = @intCast(instr.hw2 & 0xF),
            .rd = @intCast((instr.hw2 >> 8) & 0xF),
            .ra = ra,
        };
    }
};

fn spOrPc(n: u4) bool {
    return n == 13 or n == 15;
}

fn decode(instr: Instr) ?op.Exec {
    const f = Fields.of(instr) orelse return null;
    if (spOrPc(f.rd) or spOrPc(f.rn) or spOrPc(f.rm)) return null;
    if (f.kind != .mul and spOrPc(f.ra)) return null;
    return exec;
}

/// What Rd gets from the current Rn, Rm and Ra.
pub fn result(kind: Kind, rn: u32, rm: u32, ra: u32) u32 {
    const product = rn *% rm;
    return switch (kind) {
        .mul => product,
        .mla => ra +% product,
        .mls => ra -% product,
    };
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = Fields.of(instr).?;
    const ra = if (f.kind == .mul) 0 else cpu.regs.get(f.ra);
    cpu.regs.set(f.rd, result(f.kind, cpu.regs.get(f.rn), cpu.regs.get(f.rm), ra));
}
