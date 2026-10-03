//! Armv8.1-M PAC/PACBTI, PACG, AUT, AUTG and BXAUT instructions. QARMA5
//! authenticates the zero-extended pointer and modifier with the key selected
//! from the current CONTROL privilege enable and PAC key registers.
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;
const qarma = @import("../qarma.zig");
const regs = @import("../regs.zig");
const sysreg = @import("../sysreg.zig");

pub const encodings = struct {
    pub const hint_hw1: u16 = 0xF3AF;
    pub const pacbti: u8 = 0x0D;
    pub const pac: u8 = 0x1D;
    pub const aut: u8 = 0x2D;
    pub const pacg_mask: u16 = 0xFFF0;
    pub const pacg: u16 = 0xFB60;
    pub const autg_mask: u16 = 0xFFF0;
    pub const autg: u16 = 0xFB50;
};

pub const group: op.Group = .{ .name = "pac", .decode = decode, .oracle = false };

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4) return null;
    if (instr.hw1 == encodings.hint_hw1 and instr.hw2 & 0xFF00 == 0x8000) {
        return switch (@as(u8, @truncate(instr.hw2))) {
            encodings.pac => pac,
            encodings.pacbti => pacbti,
            encodings.aut => aut,
            else => null,
        };
    }
    if (instr.hw1 & encodings.pacg_mask == encodings.pacg and instr.hw2 & 0xF0F0 == 0xF000) {
        const rd: u4 = @truncate(instr.hw2 >> 8);
        const rn: u4 = @truncate(instr.hw1);
        const rm: u4 = @truncate(instr.hw2);
        return if (destination(rd) and source(rn) and source(rm)) pacg else null;
    }
    if (instr.hw1 & encodings.autg_mask == encodings.autg) {
        const form = instr.hw2 & 0x0FF0;
        if (form != 0x0F00 and form != 0x0F10) return null;
        const ra: u4 = @truncate(instr.hw2 >> 12);
        const rn: u4 = @truncate(instr.hw1);
        const rm: u4 = @truncate(instr.hw2);
        const valid = if (form == 0x0F00)
            destination(ra) and source(rn) and source(rm)
        else
            destination(ra) and destination(rn) and source(rm);
        return if (valid) (if (form == 0x0F00) autg else bxaut) else null;
    }
    return null;
}

fn destination(n: u4) bool {
    return n < 13;
}

fn source(n: u4) bool {
    return n < 15;
}

fn enabled(cpu: *const Cpu) bool {
    if (!cpu.profile.v8_1m) return false;
    const bit = if (sysreg.privileged(&cpu.regs)) regs.control_bits.pac_en else regs.control_bits.upac_en;
    return cpu.regs.control & bit != 0;
}

fn key(cpu: *const Cpu) qarma.Key {
    return if (sysreg.privileged(&cpu.regs)) cpu.regs.pac_key_p else cpu.regs.pac_key_u;
}

fn sign(cpu: *Cpu, dst: u4, pointer: u32, modifier: u32) void {
    if (enabled(cpu)) cpu.regs.set(dst, qarma.pac(pointer, modifier, key(cpu)));
}

fn authenticate(cpu: *const Cpu, code_reg: u4, pointer: u32, modifier: u32) bool {
    return !enabled(cpu) or cpu.regs.get(code_reg) == qarma.pac(pointer, modifier, key(cpu));
}

fn pac(cpu: *Cpu, instr: Instr) op.Error!void {
    _ = instr;
    sign(cpu, 12, cpu.regs.lr, cpu.regs.sp());
}

fn pacbti(cpu: *Cpu, instr: Instr) op.Error!void {
    sign(cpu, 12, cpu.regs.lr, cpu.regs.sp());
    // PACBTI is a BTI landing pad; it consumes a pending BTI check.
    cpu.regs.xpsr &= ~(@as(u32, 1) << 21);
    _ = instr;
}

fn aut(cpu: *Cpu, instr: Instr) op.Error!void {
    _ = instr;
    if (!authenticate(cpu, 12, cpu.regs.lr, cpu.regs.sp())) return error.InvalidState;
}

fn pacg(cpu: *Cpu, instr: Instr) op.Error!void {
    const rd: u4 = @truncate(instr.hw2 >> 8);
    const rn: u4 = @truncate(instr.hw1);
    const rm: u4 = @truncate(instr.hw2);
    sign(cpu, rd, cpu.regs.get(rn), cpu.regs.get(rm));
}

fn autg(cpu: *Cpu, instr: Instr) op.Error!void {
    const ra: u4 = @truncate(instr.hw2 >> 12);
    const rn: u4 = @truncate(instr.hw1);
    const rm: u4 = @truncate(instr.hw2);
    if (!authenticate(cpu, ra, cpu.regs.get(rn), cpu.regs.get(rm))) return error.InvalidState;
}

fn bxaut(cpu: *Cpu, instr: Instr) op.Error!void {
    if (!enabled(cpu)) return;
    const ra: u4 = @truncate(instr.hw2 >> 12);
    const rn: u4 = @truncate(instr.hw1);
    const rm: u4 = @truncate(instr.hw2);
    const target = cpu.regs.get(rn);
    if (!authenticate(cpu, ra, target, cpu.regs.get(rm))) return error.InvalidState;
    cpu.regs.bxWritePc(target);
}
