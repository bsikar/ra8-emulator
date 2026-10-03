//! SP- and PC-relative address arithmetic, 16-bit: ADD and SUB SP, SP, #imm7
//! (T2/T1), ADD Rd, SP, #imm8 (T1) and ADR Rd, #imm8 (T1). None of them
//! touch the flags. Stack-limit checks run at the core's instruction boundary.
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;

pub const encodings = struct {
    /// ADD/SUB SP, SP, #imm7: bits [15:8] 0xB0, bit 7 picks SUB.
    pub const sp_imm7_mask: u16 = 0xFF00;
    pub const sp_imm7: u16 = 0xB000;
    pub const sp_imm7_sub: u16 = 1 << 7;
    /// ADD Rd, SP and ADR: bits [15:11], Rd in [10:8], imm8 in [7:0].
    pub const rd_imm8_mask: u16 = 0xF800;
    pub const add_rd_sp: u16 = 0xA800;
    pub const adr: u16 = 0xA000;
};

pub const group: op.Group = .{ .name = "sp_arith", .decode = decode };

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 2) return null;
    if (instr.hw1 & encodings.sp_imm7_mask == encodings.sp_imm7) {
        return if (instr.hw1 & encodings.sp_imm7_sub != 0) subSp else addSp;
    }
    return switch (instr.hw1 & encodings.rd_imm8_mask) {
        encodings.add_rd_sp => addRdSp,
        encodings.adr => adr,
        else => null,
    };
}

fn imm7(hw1: u16) u32 {
    return @as(u32, hw1 & 0x7F) << 2;
}

fn imm8(hw1: u16) u32 {
    return @as(u32, hw1 & 0xFF) << 2;
}

fn rd(hw1: u16) u4 {
    return @intCast((hw1 >> 8) & 0x7);
}

fn addSp(cpu: *Cpu, instr: Instr) op.Error!void {
    cpu.regs.setSp(cpu.regs.sp() +% imm7(instr.hw1));
}

fn subSp(cpu: *Cpu, instr: Instr) op.Error!void {
    cpu.regs.setSp(cpu.regs.sp() -% imm7(instr.hw1));
}

fn addRdSp(cpu: *Cpu, instr: Instr) op.Error!void {
    cpu.regs.set(rd(instr.hw1), cpu.regs.sp() +% imm8(instr.hw1));
}

/// Align(PC, 4) + imm, where PC reads as the instruction's address plus 4.
fn adr(cpu: *Cpu, instr: Instr) op.Error!void {
    const base = (instr.address +% 4) & ~@as(u32, 3);
    cpu.regs.set(rd(instr.hw1), base +% imm8(instr.hw1));
}
