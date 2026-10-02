//! The 32-bit miscellaneous data processing forms: REV, REV16, RBIT and REVSH
//! (T2/T1) and CLZ (T1). Rm is encoded twice, in hw1[3:0] and hw2[3:0], and
//! the result goes to Rd. None of them touch the flags. The byte reversals
//! reuse ops/reverse.zig.
//!
//! Left unclaimed: two Rm copies that differ, Rd or Rm of SP or PC (all
//! UNPREDICTABLE), and SEL, which needs the DSP GE flags.
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;
const reverse = @import("reverse.zig");

pub const encodings = struct {
    /// hw1 with Rm ([3:0]) masked out.
    pub const mask: u16 = 0xFFF0;
    pub const rev_rbit: u16 = 0xFA90;
    pub const clz: u16 = 0xFAB0;
    /// hw2 with Rd ([11:8]) and Rm ([3:0]) masked out.
    pub const hw2_mask: u16 = 0xF0F0;
    pub const op2_rev: u16 = 0xF080;
    pub const op2_rev16: u16 = 0xF090;
    pub const op2_rbit: u16 = 0xF0A0;
    pub const op2_revsh: u16 = 0xF0B0;
};

pub const group: op.Group = .{ .name = "misc_wide", .decode = decode };

pub const Kind = enum { rev, rev16, rbit, revsh, clz };

pub const Fields = struct {
    kind: Kind,
    rd: u4,
    rm: u4,

    pub fn of(instr: Instr) ?Fields {
        if (instr.size != 4) return null;
        const op2 = instr.hw2 & encodings.hw2_mask;
        const kind: Kind = switch (instr.hw1 & encodings.mask) {
            encodings.rev_rbit => switch (op2) {
                encodings.op2_rev => .rev,
                encodings.op2_rev16 => .rev16,
                encodings.op2_rbit => .rbit,
                encodings.op2_revsh => .revsh,
                else => return null,
            },
            encodings.clz => if (op2 == encodings.op2_rev) .clz else return null,
            else => return null,
        };
        if (instr.hw1 & 0xF != instr.hw2 & 0xF) return null;
        return .{ .kind = kind, .rd = @intCast((instr.hw2 >> 8) & 0xF), .rm = @intCast(instr.hw2 & 0xF) };
    }
};

fn spOrPc(n: u4) bool {
    return n == 13 or n == 15;
}

fn decode(instr: Instr) ?op.Exec {
    const f = Fields.of(instr) orelse return null;
    if (spOrPc(f.rd) or spOrPc(f.rm)) return null;
    return exec;
}

/// What Rd gets from `value` in Rm.
pub fn result(kind: Kind, value: u32) u32 {
    return switch (kind) {
        .rev => reverse.apply(.rev, value),
        .rev16 => reverse.apply(.rev16, value),
        .revsh => reverse.apply(.revsh, value),
        .rbit => @bitReverse(value),
        .clz => @clz(value),
    };
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = Fields.of(instr).?;
    cpu.regs.set(f.rd, result(f.kind, cpu.regs.get(f.rm)));
}
