//! CLRM (T1), Armv8.1-M: zero every register in the list. hw2[12:0] name
//! R0 to R12, hw2[14] LR, and hw2[15] APSR, which clears N, Z, C, V, Q and
//! GE[3:0]. Nothing is read, so no flags but the cleared ones change.
//!
//! Left unclaimed (UNPREDICTABLE): an empty list and hw2[13] set (SP).
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;
const xpsr_bits = @import("../regs.zig").xpsr_bits;

pub const encodings = struct {
    /// LDM with Rn = PC, the space Armv8.1-M gave to CLRM.
    pub const clrm: u16 = 0xE89F;
    pub const apsr: u16 = 1 << 15;
    pub const lr: u16 = 1 << 14;
    pub const sp: u16 = 1 << 13;
    pub const low: u16 = 0x1FFF;
    /// APSR.N, Z, C and V.
    pub const nzcv: u32 = 0xF << 28;
};

pub const group: op.Group = .{ .name = "clrm", .decode = decode };

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4 or instr.hw1 != encodings.clrm) return null;
    if (instr.hw2 == 0 or instr.hw2 & encodings.sp != 0) return null;
    return exec;
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const list = instr.hw2;
    var n: u5 = 0;
    while (n < 13) : (n += 1) {
        if (list & (@as(u16, 1) << @intCast(n)) != 0) cpu.regs.set(@intCast(n), 0);
    }
    if (list & encodings.lr != 0) cpu.regs.set(14, 0);
    if (list & encodings.apsr != 0) {
        cpu.regs.xpsr &= ~(encodings.nzcv | xpsr_bits.q | xpsr_bits.ge);
    }
}
