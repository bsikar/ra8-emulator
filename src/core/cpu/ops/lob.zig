//! Armv8.1-M low-overhead loops (T1): DLS, WLS and LE.
//!
//! The encoding and the loop step live in src/core/lob.zig, and this group
//! reuses both (RA8EMU-239). DLS loads LR and falls through; WLS does the
//! same or skips the body on a zero count; LE decrements LR and branches back
//! while it stays non-zero. None of the three writes flags.
//!
//! LE takes an INVSTATE UsageFault when the FP context is active and
//! FPSCR.LTPSIZE is not 4 (RA8EMU-332, the Arm ARM's LE pseudocode):
//! LTPSIZE() reads 4 whenever no FP context is active.
//!
//! Left unclaimed: SP or PC as the DLS/WLS source (UNPREDICTABLE), and the
//! tail-predicated DLSTP, WLSTP and LETP, which belong to the MVE
//! tail-predication work under RA8EMU-24 (lob.zig's decode refuses them).
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;
const lob = @import("../../lob.zig");
const control_bits = @import("../regs.zig").control_bits;
const tail = @import("../mve/all.zig").tail;

pub const encodings = struct {
    pub const sp: u4 = 13;
    pub const pc: u4 = 15;
};

pub const group: op.Group = .{ .name = "lob", .decode = decode };

/// The decoded loop instruction, or null when this group does not claim it.
pub fn fields(instr: Instr) ?lob.Instruction {
    if (instr.size != 4) return null;
    const f = lob.decode(instr.hw1, instr.hw2) orelse return null;
    if (f.kind != .le and (f.source == encodings.sp or f.source == encodings.pc)) return null;
    return f;
}

fn decode(instr: Instr) ?op.Exec {
    _ = fields(instr) orelse return null;
    return exec;
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = fields(instr).?;
    if (f.kind == .le and ltpsize(cpu) != tail.none) return error.InvalidState;
    const source = if (f.kind == .le) 0 else cpu.regs.get(f.source);
    const s = lob.step(f, instr.address, source, cpu.regs.lr);
    cpu.regs.pc = s.next_pc;
    if (s.lr) |value| cpu.regs.lr = value;
}

/// LTPSIZE() as LE reads it: FPSCR.LTPSIZE with an FP context active, else 4.
fn ltpsize(cpu: *const Cpu) u3 {
    if (cpu.regs.control & control_bits.fpca == 0) return tail.none;
    return cpu.fp.fpscr.ltpsize;
}
