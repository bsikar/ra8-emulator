//! Load and store doubleword with an immediate offset (LDRD T1, STRD T1):
//! two words at [Rn +/- imm8*4], with P/U/W picking offset, pre-indexed and
//! post-indexed addressing. Rt goes to the lower address and Rt2 to the one
//! above it.
//!
//! Left unclaimed: P=0 W=0 (the exclusive and table-branch space), Rn = PC
//! (the literal LDRD, its own slice; a PC-based STRD is UNPREDICTABLE), SP or
//! PC as Rt or Rt2, LDRD with Rt = Rt2, and writeback with Rn equal to Rt or
//! Rt2. Every access goes through the bus.
const std = @import("std");
const op = @import("../op.zig");
const alignment = @import("../alignment.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;

pub const encodings = struct {
    /// hw1[15:9] = 0b1110100 with bit 6 set.
    pub const mask: u16 = 0xFE40;
    pub const space: u16 = 0xE840;
    pub const index: u16 = 1 << 8;
    pub const add: u16 = 1 << 7;
    pub const wback: u16 = 1 << 5;
    pub const load: u16 = 1 << 4;
};

pub const group: op.Group = .{ .name = "ldrd_strd", .decode = decode };

pub const Form = struct {
    rt: u4,
    rt2: u4,
    rn: u4,
    load: bool,
    index: bool,
    add: bool,
    wback: bool,
    offset: u32,

    pub fn of(instr: Instr) ?Form {
        if (instr.size != 4 or instr.hw1 & encodings.mask != encodings.space) return null;
        const index = instr.hw1 & encodings.index != 0;
        const wback = instr.hw1 & encodings.wback != 0;
        if (!index and !wback) return null;
        return .{
            .rt = @intCast(instr.hw2 >> 12),
            .rt2 = @intCast((instr.hw2 >> 8) & 0xF),
            .rn = @intCast(instr.hw1 & 0xF),
            .load = instr.hw1 & encodings.load != 0,
            .index = index,
            .add = instr.hw1 & encodings.add != 0,
            .wback = wback,
            .offset = @as(u32, instr.hw2 & 0xFF) << 2,
        };
    }

    /// Whether the register choices are architecturally defined.
    pub fn allowed(self: Form) bool {
        if (self.rn == 15) return false;
        if (spOrPc(self.rt) or spOrPc(self.rt2)) return false;
        if (self.load and self.rt == self.rt2) return false;
        if (self.wback and (self.rn == self.rt or self.rn == self.rt2)) return false;
        return true;
    }
};

fn spOrPc(n: u4) bool {
    return n == 13 or n == 15;
}

fn decode(instr: Instr) ?op.Exec {
    const form = Form.of(instr) orelse return null;
    if (!form.allowed()) return null;
    return if (form.load) ldrd else strd;
}

fn addresses(cpu: *const Cpu, form: Form) struct { access: u32, after: u32 } {
    const base = cpu.regs.get(form.rn);
    const after = if (form.add) base +% form.offset else base -% form.offset;
    return .{ .access = if (form.index) after else base, .after = after };
}

fn ldrd(cpu: *Cpu, instr: Instr) op.Error!void {
    const form = Form.of(instr).?;
    const at = addresses(cpu, form);
    try alignment.memA(at.access, 8);
    const low = try cpu.bus.readWord(at.access);
    const high = try cpu.bus.readWord(at.access +% 4);
    cpu.regs.set(form.rt, low);
    cpu.regs.set(form.rt2, high);
    if (form.wback) cpu.regs.set(form.rn, at.after);
}

fn strd(cpu: *Cpu, instr: Instr) op.Error!void {
    const form = Form.of(instr).?;
    const at = addresses(cpu, form);
    try alignment.memA(at.access, 8);
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], cpu.regs.get(form.rt), .little);
    std.mem.writeInt(u32, bytes[4..8], cpu.regs.get(form.rt2), .little);
    try cpu.bus.write(at.access, bytes[0..4]);
    try cpu.bus.write(at.access +% 4, bytes[4..8]);
    if (form.wback) cpu.regs.set(form.rn, at.after);
}
