//! VCMP and VCMPE (T1 register, T2 against +0.0), single and double
//! precision, and the FPSCR transfers VMRS and VMSR.
//!
//! VCMP{E}: hw1 is 1110 1110 1 D 11 010z and hw2 is Vd 101 sz E 1 M 0 Vm,
//! with z set for the compare with zero, whose M and Vm must be zero. The
//! result goes to FPSCR.NZCV; E makes a quiet NaN signal IOC as well.
//!
//! VMRS: 1110 1110 1111 0001, Rt 1010 0001 0000. Rt = 15 is the
//! APSR_nzcv form, which copies FPSCR.NZCV into the APSR flags. VMSR:
//! 1110 1110 1110 0001, same hw2. Only the FPSCR register field (0001) is
//! decoded here; the Armv8.1-M VPR, P0 and FPCXT forms are not. SP as Rt,
//! and PC for VMSR, stay unclaimed.
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;
const fpu = @import("../fpu/all.zig");
const Format = fpu.format.Format;
const Fpscr = fpu.fpscr.Fpscr;
const fp_regs = @import("fp_regs.zig");

pub const group: op.Group = .{ .name = "fp_system", .decode = decode, .oracle = false };

pub const encodings = struct {
    pub const vmrs: u16 = 0xEEF1;
    pub const vmsr: u16 = 0xEEE1;
    /// hw2 of VMRS and VMSR with Rt ([15:12]) masked out.
    pub const transfer_hw2: u16 = 0x0A10;
};

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4) return null;
    if (instr.hw2 & 0x0FFF == encodings.transfer_hw2) return decodeTransfer(instr);
    if (instr.hw1 & 0xFFBE != 0xEEB4 or instr.hw2 & 0x0E50 != 0x0A40) return null;
    const zero = instr.hw1 & 1 == 1;
    if (zero and instr.hw2 & 0x002F != 0) return null;
    const double = instr.hw2 >> 8 & 1 == 1;
    if (!fp_regs.exists(dReg(instr, double), double)) return null;
    if (!zero and !fp_regs.exists(mReg(instr, double), double)) return null;
    if (double) return if (zero) compareFor(fpu.format.double, true) else compareFor(fpu.format.double, false);
    return if (zero) compareFor(fpu.format.single, true) else compareFor(fpu.format.single, false);
}

fn decodeTransfer(instr: Instr) ?op.Exec {
    const rt = instr.hw2 >> 12;
    return switch (instr.hw1) {
        encodings.vmrs => if (rt == 13) null else &vmrs,
        encodings.vmsr => if (rt == 13 or rt == 15) null else &vmsr,
        else => null,
    };
}

pub fn dReg(instr: Instr, double: bool) u5 {
    return fp_regs.index(@intCast(instr.hw2 >> 12), @intCast(instr.hw1 >> 6 & 1), double);
}

pub fn mReg(instr: Instr, double: bool) u5 {
    return fp_regs.index(@intCast(instr.hw2 & 0xF), @intCast(instr.hw2 >> 5 & 1), double);
}

/// Writes a compare result into FPSCR.NZCV.
pub fn setNzcv(fpscr: *Fpscr, nzcv: u4) void {
    fpscr.n = @intCast(nzcv >> 3);
    fpscr.z = @intCast(nzcv >> 2 & 1);
    fpscr.c = @intCast(nzcv >> 1 & 1);
    fpscr.v = @intCast(nzcv & 1);
}

fn compareFor(comptime fmt: Format, comptime zero: bool) op.Exec {
    return struct {
        fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
            const double = comptime fmt.width() == 64;
            const bank = &cpu.fp.bank;
            const a = fp_regs.read(fmt, bank, dReg(instr, double));
            const b: fmt.Bits() = if (zero) 0 else fp_regs.read(fmt, bank, mReg(instr, double));
            const signal = instr.hw2 >> 7 & 1 == 1;
            setNzcv(&cpu.fp.fpscr, fpu.compare.compare(fmt, a, b, signal, &cpu.fp.fpscr));
        }
    }.exec;
}

fn vmrs(cpu: *Cpu, instr: Instr) op.Error!void {
    const rt: u4 = @intCast(instr.hw2 >> 12);
    if (rt == 15) {
        cpu.regs.xpsr = (cpu.regs.xpsr & 0x0FFF_FFFF) | cpu.fp.fpscr.apsrNzcv();
        return;
    }
    cpu.regs.set(rt, cpu.fp.fpscr.bits());
}

fn vmsr(cpu: *Cpu, instr: Instr) op.Error!void {
    cpu.fp.fpscr = Fpscr.fromBits(cpu.regs.get(@intCast(instr.hw2 >> 12)));
}
