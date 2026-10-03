//! SDIV and UDIV (T1): Rd = Rn / Rm, rounding toward zero. Neither touches
//! the flags. A zero divisor gives 0 unless CCR.DIV_0_TRP asks for UsageFault.
//! SDIV of INT_MIN by -1
//! wraps to INT_MIN. SP or PC in any field is UNPREDICTABLE and left
//! unclaimed, so the core stops rather than guess.
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;
const memmap = @import("../../memmap.zig");

pub const encodings = struct {
    /// hw1 with Rn ([3:0]) masked out.
    pub const hw1_mask: u16 = 0xFFF0;
    pub const sdiv: u16 = 0xFB90;
    pub const udiv: u16 = 0xFBB0;
    /// hw2 with Rd ([11:8]) and Rm ([3:0]) masked out.
    pub const hw2_mask: u16 = 0xF0F0;
    pub const hw2_fixed: u16 = 0xF0F0;
};

pub const group: op.Group = .{ .name = "divide", .decode = decode };

/// The three registers an encoding names.
pub const Fields = struct { rd: u4, rn: u4, rm: u4 };

pub fn fields(instr: Instr) Fields {
    return .{
        .rd = @intCast((instr.hw2 >> 8) & 0xF),
        .rn = @intCast(instr.hw1 & 0xF),
        .rm = @intCast(instr.hw2 & 0xF),
    };
}

fn unpredictable(n: u4) bool {
    return n == 13 or n == 15;
}

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4 or instr.hw2 & encodings.hw2_mask != encodings.hw2_fixed) return null;
    const f = fields(instr);
    if (unpredictable(f.rd) or unpredictable(f.rn) or unpredictable(f.rm)) return null;
    return switch (instr.hw1 & encodings.hw1_mask) {
        encodings.sdiv => sdiv,
        encodings.udiv => udiv,
        else => null,
    };
}

/// Signed quotient toward zero; 0 for a zero divisor.
pub fn signedQuotient(n: u32, m: u32) u32 {
    if (m == 0) return 0;
    const a: i32 = @bitCast(n);
    const b: i32 = @bitCast(m);
    if (a == @as(i32, @bitCast(@as(u32, 0x8000_0000))) and b == -1) return n;
    return @bitCast(@divTrunc(a, b));
}

/// Unsigned quotient; 0 for a zero divisor.
pub fn unsignedQuotient(n: u32, m: u32) u32 {
    return if (m == 0) 0 else n / m;
}

fn sdiv(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = fields(instr);
    cpu.regs.set(f.rd, signedQuotient(cpu.regs.get(f.rn), cpu.regs.get(f.rm)));
}

fn udiv(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = fields(instr);
    cpu.regs.set(f.rd, unsignedQuotient(cpu.regs.get(f.rn), cpu.regs.get(f.rm)));
}

/// Whether this divide raises DIVBYZERO under the active CCR.
pub fn traps(cpu: *const Cpu, instr: Instr) bool {
    const f = fields(instr);
    if (cpu.regs.get(f.rm) != 0) return false;
    return (cpu.bus.readWord(memmap.scb.ccr) catch 0) & div_0_trp != 0;
}

const div_0_trp: u32 = 1 << 4;
