//! The DSP parallel adds and subtracts (T1): ADD16, ASX, SAX, SUB16, ADD8 and
//! SUB8, each with the S, Q, SH, U, UQ and UH prefixes. Every byte or halfword
//! lane is worked on its own. The modular S and U forms write APSR.GE (one bit
//! per byte); the saturating and halving forms leave GE and Q alone.
//!
//! Left unclaimed: SP or PC in Rd, Rn or Rm (UNPREDICTABLE), op1 011 and 111,
//! and op2 11.
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;
const xpsr_bits = @import("../regs.zig").xpsr_bits;

pub const encodings = struct {
    /// hw1[15:7]; op1 is hw1[6:4] and Rn hw1[3:0].
    pub const mask: u16 = 0xFF80;
    pub const space: u16 = 0xFA80;
    /// hw2[15:12] set and hw2[7] clear; Rd, U (hw2[6]), op2 and Rm vary.
    pub const hw2_mask: u16 = 0xF080;
    pub const hw2_fixed: u16 = 0xF000;
};

pub const Shape = enum { add8, add16, asx, sub8, sub16, sax };

/// op2 (hw2[5:4]).
pub const Mode = enum(u2) { modular = 0, saturating = 1, halving = 2 };

pub const group: op.Group = .{ .name = "parallel", .decode = decode };

pub const Fields = struct {
    shape: Shape,
    signed: bool,
    mode: Mode,
    rn: u4,
    rd: u4,
    rm: u4,

    pub fn of(instr: Instr) ?Fields {
        if (instr.size != 4 or instr.hw1 & encodings.mask != encodings.space) return null;
        if (instr.hw2 & encodings.hw2_mask != encodings.hw2_fixed) return null;
        const shape: Shape = switch ((instr.hw1 >> 4) & 0x7) {
            0 => .add8,
            1 => .add16,
            2 => .asx,
            4 => .sub8,
            5 => .sub16,
            6 => .sax,
            else => return null,
        };
        const op2: u2 = @intCast((instr.hw2 >> 4) & 0x3);
        if (op2 == 3) return null;
        return .{
            .shape = shape,
            .signed = instr.hw2 & 0x40 == 0,
            .mode = @fromBackingInt(@intCast(op2)),
            .rn = @intCast(instr.hw1 & 0xF),
            .rd = @intCast((instr.hw2 >> 8) & 0xF),
            .rm = @intCast(instr.hw2 & 0xF),
        };
    }
};

/// What Rd gets, and the GE bits a modular form writes.
pub const Result = struct { value: u32, ge: u4 };

const Lane = struct { sub: bool, m_lane: u2 };

fn width(shape: Shape) u5 {
    return switch (shape) {
        .add8, .sub8 => 8,
        else => 16,
    };
}

fn plan(shape: Shape, i: u2) Lane {
    return switch (shape) {
        .add8, .add16 => .{ .sub = false, .m_lane = i },
        .sub8, .sub16 => .{ .sub = true, .m_lane = i },
        .asx => .{ .sub = i == 0, .m_lane = 1 - i },
        .sax => .{ .sub = i == 1, .m_lane = 1 - i },
    };
}

fn laneMask(bits: u5) u32 {
    return (@as(u32, 1) << bits) - 1;
}

fn lane(value: u32, i: u2, bits: u5, signed: bool) i32 {
    const raw: i32 = @intCast((value >> (@as(u5, i) * bits)) & laneMask(bits));
    const top: i32 = @as(i32, 1) << (bits - 1);
    return if (signed and raw & top != 0) raw - (top << 1) else raw;
}

fn clamp(r: i32, bits: u5, signed: bool) i32 {
    const span: i32 = @as(i32, 1) << bits;
    const lo: i32 = if (signed) -(span >> 1) else 0;
    const hi: i32 = if (signed) (span >> 1) - 1 else span - 1;
    return @max(lo, @min(hi, r));
}

fn geSet(r: i32, bits: u5, signed: bool, sub: bool) bool {
    if (!signed and !sub) return r >= @as(i32, 1) << bits;
    return r >= 0;
}

/// Works `f` on Rn = `n` and Rm = `m`.
pub fn compute(f: Fields, n: u32, m: u32) Result {
    const bits = width(f.shape);
    const count: u3 = if (bits == 8) 4 else 2;
    var out: Result = .{ .value = 0, .ge = 0 };
    var i: u3 = 0;
    while (i < count) : (i += 1) {
        const at: u2 = @intCast(i);
        const l = plan(f.shape, at);
        const a = lane(n, at, bits, f.signed);
        const b = lane(m, l.m_lane, bits, f.signed);
        const r = if (l.sub) a - b else a + b;
        const v: i32 = switch (f.mode) {
            .modular => r,
            .saturating => clamp(r, bits, f.signed),
            .halving => r >> 1,
        };
        out.value |= (@as(u32, @bitCast(v)) & laneMask(bits)) << (@as(u5, at) * bits);
        if (f.mode == .modular and geSet(r, bits, f.signed, l.sub)) {
            out.ge |= if (bits == 8) @as(u4, 1) << at else @as(u4, 3) << (at * 2);
        }
    }
    return out;
}

fn spOrPc(n: u4) bool {
    return n == 13 or n == 15;
}

fn decode(instr: Instr) ?op.Exec {
    const f = Fields.of(instr) orelse return null;
    if (spOrPc(f.rd) or spOrPc(f.rn) or spOrPc(f.rm)) return null;
    return exec;
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = Fields.of(instr).?;
    const r = compute(f, cpu.regs.get(f.rn), cpu.regs.get(f.rm));
    cpu.regs.set(f.rd, r.value);
    if (f.mode != .modular) return;
    const ge: u32 = @as(u32, r.ge) << xpsr_bits.ge_shift;
    cpu.regs.xpsr = (cpu.regs.xpsr & ~xpsr_bits.ge) | ge;
}
