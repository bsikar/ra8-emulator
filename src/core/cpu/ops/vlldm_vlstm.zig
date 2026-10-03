//! VLLDM and VLSTM (T1, and the Armv8.1-M T2 forms), the lazy FP context
//! load and store Secure code runs around a call into Non-secure code.
//!
//!   hw1 1110 1100 001 L Rn    hw2 0000 1010 T 000 0000
//!
//! L set is VLLDM. T set is the T2 form (D0-D31 in the register list), which
//! needs Armv8.1-M; the two forms behave the same here, as in QEMU's
//! trans_VLLDM_VLSTM. Rn = PC is UNPREDICTABLE and stays unclaimed.
//!
//! Per DDI0553: from Non-secure state both are UNDEFINED. With
//! CONTROL.SFPA clear both are NOPs. Rn must be 8-byte aligned. The frame
//! is the extended one: S0-S15 at 0, FPSCR at 0x40, VPR at 0x44 (MVE),
//! S16-S31 from 0x48 when FPCCR.TS is set.
//! - VLSTM with FPCCR.LSPEN clear stores the context now (and with TS set
//!   clears the registers, FPSCR and VPR); with LSPEN set it only arms lazy
//!   preservation: FPCAR = Rn, LSPACT, S, USER and THREAD. Either way it
//!   clears CONTROL.FPCA.
//! - VLLDM with LSPACT set just clears it (nothing was stored); otherwise
//!   it loads the context back. Either way it sets CONTROL.FPCA.
//!
//! Not modelled yet (RA8EMU-351): the CPACR/NSACR NOCP check and the
//! LSERR SecureFault VLSTM takes when LSPACT is already set.
const std = @import("std");
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;
const Fpscr = @import("../fpu/fpscr.zig").Fpscr;
const control_bits = @import("../regs.zig").control_bits;

pub const encodings = struct {
    pub const mask: u16 = 0xFFE0;
    pub const first: u16 = 0xEC20;
    pub const load_bit: u16 = 1 << 4;
    pub const second_mask: u16 = 0xFF7F;
    pub const second: u16 = 0x0A00;
    pub const t2_bit: u16 = 1 << 7;
    pub const pc: u4 = 15;
};

pub const offset = struct {
    pub const fpscr: u32 = 0x40;
    pub const vpr: u32 = 0x44;
    pub const high: u32 = 0x48;
};

pub const Fields = struct { load: bool, t2: bool, rn: u4 };

/// T1 runs on every Armv8-M core with an FPU; T2 is registered behind v8_1m.
pub const group: op.Group = .{ .name = "vlldm_vlstm", .decode = decodeT1, .oracle = false };
pub const group_t2: op.Group = .{ .name = "vlldm_vlstm_t2", .decode = decodeT2, .oracle = false };

/// The decoded instruction, or null when neither form claims it.
pub fn fields(instr: Instr) ?Fields {
    const e = encodings;
    if (instr.size != 4 or instr.hw1 & e.mask != e.first) return null;
    if (instr.hw2 & e.second_mask != e.second) return null;
    const rn: u4 = @truncate(instr.hw1);
    if (rn == e.pc) return null;
    return .{ .load = instr.hw1 & e.load_bit != 0, .t2 = instr.hw2 & e.t2_bit != 0, .rn = rn };
}

fn decodeT1(instr: Instr) ?op.Exec {
    const f = fields(instr) orelse return null;
    return if (f.t2) null else exec;
}

fn decodeT2(instr: Instr) ?op.Exec {
    const f = fields(instr) orelse return null;
    return if (f.t2) exec else null;
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = fields(instr).?;
    if (cpu.banked.current != .secure) return error.Undefined;
    if (cpu.regs.control & control_bits.sfpa == 0) return;
    const at = cpu.regs.get(f.rn);
    if (at & 7 != 0) return error.Unaligned;
    if (f.load) return load(cpu, at);
    return store(cpu, at);
}

fn store(cpu: *Cpu, at: u32) op.Error!void {
    const fp = &cpu.fp;
    if (fp.context.fpccr.lspen == 1) {
        fp.context.writeFpcar(at);
        const handler = cpu.regs.handlerMode();
        fp.context.fpccr.lspact = 1;
        fp.context.fpccr.s = 1;
        fp.context.fpccr.thread = @intFromBool(!handler);
        fp.context.fpccr.user = @intFromBool(!handler and cpu.regs.control & control_bits.npriv != 0);
    } else {
        const ts = fp.context.fpccr.ts == 1;
        for (0..words(ts)) |i| try put(cpu, at +% slot(i), fp.bank.readS(@intCast(i)));
        try put(cpu, at +% offset.fpscr, fp.fpscr.bits());
        if (cpu.profile.mve) try put(cpu, at +% offset.vpr, @bitCast(fp.vpr));
        if (ts) {
            for (0..32) |i| fp.bank.writeS(@intCast(i), 0);
            fp.fpscr = Fpscr.fromBits(0);
            fp.vpr = @bitCast(@as(u32, 0));
        }
    }
    cpu.regs.control &= ~control_bits.fpca;
}

fn load(cpu: *Cpu, at: u32) op.Error!void {
    const fp = &cpu.fp;
    if (fp.context.fpccr.lspact == 1) {
        fp.context.fpccr.lspact = 0;
    } else {
        const ts = fp.context.fpccr.ts == 1;
        for (0..words(ts)) |i| fp.bank.writeS(@intCast(i), try get(cpu, at +% slot(i)));
        fp.fpscr = Fpscr.fromBits(try get(cpu, at +% offset.fpscr));
        if (cpu.profile.mve) fp.vpr = @bitCast(try get(cpu, at +% offset.vpr));
    }
    cpu.regs.control |= control_bits.fpca;
}

/// S registers in the frame: 16, or all 32 when FPCCR.TS is set.
fn words(ts: bool) usize {
    return if (ts) 32 else 16;
}

/// Frame offset of S[i]: S16-S31 sit after the FPSCR and VPR words.
pub fn slot(i: usize) u32 {
    const n: u32 = @intCast(i);
    return if (n < 16) n * 4 else offset.high + (n - 16) * 4;
}

fn put(cpu: *Cpu, address: u32, value: u32) op.Error!void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try cpu.bus.write(address, &bytes);
}

fn get(cpu: *Cpu, address: u32) op.Error!u32 {
    var bytes: [4]u8 = undefined;
    try cpu.bus.read(address, &bytes);
    return std.mem.readInt(u32, &bytes, .little);
}
