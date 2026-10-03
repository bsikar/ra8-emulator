//! BXNS (T1), the Secure side's branch back to Non-secure code, with a real
//! change of security state (RA8EMU-271).
//!
//! From Secure state, a target with bit 0 clear switches the core to
//! Non-secure through Banked.switchTo (each state's MSP, PSP, stack limits,
//! PRIMASK, BASEPRI, FAULTMASK and banked CONTROL bits trade places) and
//! branches there. A target with bit 0 set stays Secure and is an ordinary
//! BX, which is also what a Secure function entered through an SG with the
//! core already Secure ends in. In Non-secure state BXNS is UNDEFINED.
//!
//! Left unclaimed: Rm of SP or PC. FNC_RETURN targets arrive with
//! RA8EMU-32; until then they take the BX path.
//!
//! Not checked against Unicorn: its flat domain has no security state, so a
//! lockstep run steps only the Zig core for BXNS.
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;

pub const encodings = struct {
    pub const mask: u16 = 0xFF87;
    pub const bxns: u16 = 0x4704;
};

pub const group: op.Group = .{ .name = "bxns", .decode = decode, .oracle = false };

fn register(hw1: u16) u4 {
    return @intCast((hw1 >> 3) & 0xF);
}

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 2 or instr.hw1 & encodings.mask != encodings.bxns) return null;
    const rm = register(instr.hw1);
    if (rm == 13 or rm == 15) return null;
    return branch;
}

fn branch(cpu: *Cpu, instr: Instr) op.Error!void {
    if (cpu.banked.current != .secure) return error.Undefined;
    const target = cpu.regs.get(register(instr.hw1));
    if (target & 1 != 0) return cpu.regs.bxWritePc(target);
    cpu.banked.switchTo(&cpu.regs, .non_secure);
    cpu.regs.pc = target;
}
