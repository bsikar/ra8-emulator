//! The bitfield instructions with a plain binary immediate: SBFX and UBFX
//! extract a field and sign- or zero-extend it, BFI inserts the low bits of
//! Rn into Rd, and BFC (BFI with Rn = PC) clears a field of Rd. None of them
//! touch the flags.
//!
//! Left unclaimed as UNPREDICTABLE: Rd or Rn of SP or PC (Rn = PC is BFC), an
//! extract running past bit 31, and an insert whose msb sits below its lsb.
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;

pub const encodings = struct {
    /// hw1 with Rn ([3:0]) masked out.
    pub const mask: u16 = 0xFFF0;
    pub const sbfx: u16 = 0xF340;
    pub const bfi: u16 = 0xF360;
    pub const ubfx: u16 = 0xF3C0;
    /// hw2[15] and hw2[5] are zero in all three.
    pub const hw2_zero: u16 = 0x8020;
};

pub const group: op.Group = .{ .name = "bitfield", .decode = decode };

pub const Kind = enum { sbfx, ubfx, bfi };

pub const Fields = struct {
    kind: Kind,
    rn: u4,
    rd: u4,
    lsb: u5,
    /// widthm1 for the extracts, msb for the insert.
    top: u5,

    pub fn of(instr: Instr) ?Fields {
        if (instr.size != 4 or instr.hw2 & encodings.hw2_zero != 0) return null;
        const kind: Kind = switch (instr.hw1 & encodings.mask) {
            encodings.sbfx => .sbfx,
            encodings.ubfx => .ubfx,
            encodings.bfi => .bfi,
            else => return null,
        };
        const imm3: u5 = @intCast((instr.hw2 >> 12) & 0x7);
        const imm2: u5 = @intCast((instr.hw2 >> 6) & 0x3);
        return .{
            .kind = kind,
            .rn = @intCast(instr.hw1 & 0xF),
            .rd = @intCast((instr.hw2 >> 8) & 0xF),
            .lsb = (imm3 << 2) | imm2,
            .top = @intCast(instr.hw2 & 0x1F),
        };
    }

    /// Whether this is an encoding the architecture defines a result for.
    pub fn valid(self: Fields) bool {
        if (self.rd == 13 or self.rd == 15 or self.rn == 13) return false;
        return switch (self.kind) {
            .bfi => self.top >= self.lsb,
            .sbfx, .ubfx => self.rn != 15 and @as(u6, self.lsb) + self.top <= 31,
        };
    }
};

fn decode(instr: Instr) ?op.Exec {
    const f = Fields.of(instr) orelse return null;
    return if (f.valid()) exec else null;
}

/// A mask of `width` ones starting at bit 0; `width` is 1 to 32.
pub fn ones(width: u6) u32 {
    return if (width == 32) ~@as(u32, 0) else (@as(u32, 1) << @intCast(width)) - 1;
}

/// The value Rd gets, given the current Rn (0 for BFC) and Rd.
pub fn result(f: Fields, rn: u32, rd: u32) u32 {
    switch (f.kind) {
        .bfi => {
            const field = ones(@as(u6, f.top) - f.lsb + 1) << f.lsb;
            return (rd & ~field) | ((rn << f.lsb) & field);
        },
        .ubfx => return (rn >> f.lsb) & ones(@as(u6, f.top) + 1),
        .sbfx => {
            const shl: u5 = @intCast(31 - (@as(u6, f.lsb) + f.top));
            const shr: u5 = @intCast(31 - @as(u6, f.top));
            const signed: i32 = @bitCast(rn << shl);
            return @bitCast(signed >> shr);
        },
    }
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = Fields.of(instr).?;
    const rn = if (f.rn == 15) 0 else cpu.regs.get(f.rn);
    cpu.regs.set(f.rd, result(f, rn, cpu.regs.get(f.rd)));
}
