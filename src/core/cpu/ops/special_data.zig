//! The 16-bit special data and branch-exchange block (0x4400-0x47FF): ADD
//! and MOV with any register (T2/T1), CMP with a high register (T2), BX and
//! BLX by register. A read of R15 here is the instruction address plus 4.
//! ADD and MOV to the PC branch without changing state; BX and BLX take
//! EPSR.T from bit 0, and BX to an EXC_RETURN value in Handler mode is an
//! exception return (src/core/cpu/exception/ret.zig). FNC_RETURN is RA8EMU-18's;
//! BXNS and BLXNS (bit 2 set) belong to TrustZone and stay unclaimed, as do
//! the UNPREDICTABLE forms.
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;
const flags = @import("../flags.zig");
const regs = @import("../regs.zig");

pub const encodings = struct {
    pub const op_mask: u16 = 0xFF00;
    pub const add: u16 = 0x4400;
    pub const cmp: u16 = 0x4500;
    pub const mov: u16 = 0x4600;
    /// BX and BLX keep bits [2:0] zero; bit 7 picks BLX.
    pub const bx_mask: u16 = 0xFF87;
    pub const bx: u16 = 0x4700;
    pub const blx: u16 = 0x4780;
};

pub const group: op.Group = .{ .name = "special_data", .decode = decode };

/// D:Rd (or N:Rn), bits [7] and [2:0].
fn first(hw1: u16) u4 {
    return @intCast(((hw1 >> 4) & 0x8) | (hw1 & 0x7));
}

fn second(hw1: u16) u4 {
    return @intCast((hw1 >> 3) & 0xF);
}

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 2) return null;
    const hw1 = instr.hw1;
    const d = first(hw1);
    const m = second(hw1);
    return switch (hw1 & encodings.op_mask) {
        encodings.add => if (d == 15 and m == 15) null else add,
        encodings.cmp => if ((d < 8 and m < 8) or d == 15 or m == 15) null else cmp,
        encodings.mov => mov,
        else => switch (hw1 & encodings.bx_mask) {
            encodings.bx => bx,
            encodings.blx => if (m == 15) null else blx,
            else => null,
        },
    };
}

fn read(cpu: *const Cpu, instr: Instr, n: u4) u32 {
    return if (n == 15) instr.address +% 4 else cpu.regs.get(n);
}

/// ALUWritePC for R15, a plain write otherwise.
fn write(cpu: *Cpu, n: u4, value: u32) void {
    if (n == 15) cpu.regs.pc = value & ~@as(u32, 1) else cpu.regs.set(n, value);
}

/// BXWritePC / BLXWritePC: bit 0 becomes EPSR.T, the rest the PC, and an
/// EXC_RETURN value in Handler mode is an exception return.
fn exchange(cpu: *Cpu, value: u32) void {
    cpu.regs.bxWritePc(value);
}

fn add(cpu: *Cpu, instr: Instr) op.Error!void {
    const d = first(instr.hw1);
    write(cpu, d, read(cpu, instr, d) +% read(cpu, instr, second(instr.hw1)));
}

fn cmp(cpu: *Cpu, instr: Instr) op.Error!void {
    const x = read(cpu, instr, first(instr.hw1));
    const y = read(cpu, instr, second(instr.hw1));
    flags.setNZCV(&cpu.regs, flags.addWithCarry(x, ~y, true));
}

fn mov(cpu: *Cpu, instr: Instr) op.Error!void {
    write(cpu, first(instr.hw1), read(cpu, instr, second(instr.hw1)));
}

fn bx(cpu: *Cpu, instr: Instr) op.Error!void {
    exchange(cpu, read(cpu, instr, second(instr.hw1)));
}

fn blx(cpu: *Cpu, instr: Instr) op.Error!void {
    const target = cpu.regs.get(second(instr.hw1));
    cpu.regs.set(14, (instr.address +% 2) | 1);
    exchange(cpu, target);
}
