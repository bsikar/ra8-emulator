//! CBZ and CBNZ (T1): branch forward by i:imm5:'0' when Rn is (or is not)
//! zero. Flags are untouched. The target is relative to the PC the
//! instruction sees, its own address plus 4. Inside an IT block either form
//! is UNPREDICTABLE; IT itself arrives later in RA8EMU-13.
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;

pub const encodings = struct {
    pub const mask: u16 = 0xF500;
    pub const cb: u16 = 0xB100;
    /// Set for CBNZ.
    pub const nonzero: u16 = 1 << 11;
};

pub const group: op.Group = .{ .name = "cbz", .decode = decode };

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 2 or instr.hw1 & encodings.mask != encodings.cb) return null;
    return run;
}

/// The byte offset an encoding branches by: i:imm5:'0', 0 to 126.
pub fn offset(hw1: u16) u32 {
    const imm5: u32 = (hw1 >> 3) & 0x1F;
    const i: u32 = (hw1 >> 9) & 1;
    return (i << 6) | (imm5 << 1);
}

fn run(cpu: *Cpu, instr: Instr) op.Error!void {
    const rn: u4 = @intCast(instr.hw1 & 7);
    const zero = cpu.regs.get(rn) == 0;
    const wants_nonzero = instr.hw1 & encodings.nonzero != 0;
    if (zero == wants_nonzero) return;
    cpu.regs.pc = instr.address +% 4 +% offset(instr.hw1);
}
