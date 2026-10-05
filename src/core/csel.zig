//! Armv8.1-M conditional select: CSEL, CSINC, CSINV and CSNEG.
//!
//! Same gap as the low-overhead loops next door, and found the same way. An
//! Armv8.0-M CPU model rejects these four encodings outright, and a compiler targeting a Cortex-M85 reaches for
//! them wherever a C ternary or a boolean result would otherwise cost a
//! branch. `ra8_mpu_abi.validateCfg` is the case that pushed this: it ends in
//!
//!     cmp   r0, #0
//!     cset  r0, eq
//!
//! and threadx_mpu_partition_demo stopped dead on that second instruction,
//! as did wdt_supervisor_demo on the same construct elsewhere. Two apps, one
//! missing opcode.
//!
//! The four are one instruction with four tails. When the condition holds the
//! destination takes Rn whichever it is; when it does not, the destination
//! takes Rm put through the tail: as it stands for CSEL, plus one for CSINC,
//! inverted for CSINV, negated for CSNEG. That is also what makes the aliases
//! work, and the aliases are what a compiler actually emits:
//!
//!     cset  rd, cond   = csinc rd, zr, zr, invert(cond)
//!     csetm rd, cond   = csinv rd, zr, zr, invert(cond)
//!     cinc  rd, rn, c  = csinc rd, rn, rn, invert(c)
//!
//! so nothing here special-cases them. Register 0b1111 in the Rn or Rm field
//! is the zero register, not the PC, which is what lets one encoding carry
//! both `cset` and a three-register select.
//!
//! NONE OF THESE WRITE FLAGS. There is no S variant in the family, so a run
//! through here leaves APSR exactly as it found it, and the `cmp` before it
//! still governs whatever comes after.
//!
//! The encodings below were taken from arm-none-eabi-as 13.3.rel1 assembling
//! each mnemonic for armv8.1-m.main and reading back the halfwords, not from
//! memory of the manual.
const std = @import("std");

/// CLRM, the other Armv8.1-M gap the CMSE entry stub hits. Reached from here
/// because src/root.zig is at its 400-line limit (RA8EMU-63).
pub const clrm = @import("clrm.zig");
pub const fp_context = @import("fp_context.zig");
/// TT from the board's SAU rather than the CPU model's (RA8EMU-348).
pub const tt = @import("tt.zig");

/// Which tail runs when the condition fails.
pub const Kind = enum { sel, inc, inv, neg };

pub const Instruction = struct {
    kind: Kind,
    /// Taken when the condition holds. 0b1111 is the zero register.
    then_source: u4,
    /// Put through the tail when it does not. 0b1111 is the zero register.
    else_source: u4,
    destination: u4,
    condition: u4,
};

/// The encoding, grouped rather than left loose so the decoder reads as the
/// thing it implements.
pub const encoding = struct {
    /// Both halfwords, so a caller knows how far to step past one.
    pub const width: u32 = 4;
    /// All four share a first halfword: 0xEA5n, with n the then-source.
    pub const first_mask: u16 = 0xFFF0;
    pub const first: u16 = 0xEA50;
    pub const source_mask: u16 = 0x000F;
    /// The second halfword: kind in [15:12], Rd in [11:8], condition in
    /// [7:4], else-source in [3:0].
    pub const kind_shift: u4 = 12;
    pub const destination_shift: u4 = 8;
    pub const condition_shift: u4 = 4;
    pub const nibble: u16 = 0xF;
    /// The kind field's four values, in the order the architecture numbers
    /// them.
    pub const sel: u16 = 0x8;
    pub const inc: u16 = 0x9;
    pub const inv: u16 = 0xA;
    pub const neg: u16 = 0xB;
    /// Reading this register number gives zero rather than the PC.
    pub const zero_register: u4 = 0b1111;
    /// SP in any of the three register fields is UNPREDICTABLE, and so is AL
    /// or the unconditional encoding in the condition field: a select with no
    /// condition is a move, and a compiler emits the move.
    pub const stack_register: u4 = 0b1101;
    pub const first_unconditional: u4 = 0b1110;
};

/// The four APSR flags, by the bit each sits on.
pub const flag = struct {
    pub const negative: u32 = 1 << 31;
    pub const zero: u32 = 1 << 30;
    pub const carry: u32 = 1 << 29;
    pub const overflow: u32 = 1 << 28;
};

/// Read one encoding, or null when this is not one of the four. Anything
/// UNPREDICTABLE is refused rather than guessed at, so it stays the fault it
/// should be instead of running as something invented here.
pub fn decode(first_half: u16, second_half: u16) ?Instruction {
    if (first_half & encoding.first_mask != encoding.first) return null;
    const kind: Kind = switch (second_half >> encoding.kind_shift) {
        encoding.sel => .sel,
        encoding.inc => .inc,
        encoding.inv => .inv,
        encoding.neg => .neg,
        else => return null,
    };
    const found = Instruction{
        .kind = kind,
        .then_source = @intCast(first_half & encoding.source_mask),
        .else_source = @intCast(second_half & encoding.nibble),
        .destination = @intCast((second_half >> encoding.destination_shift) & encoding.nibble),
        .condition = @intCast((second_half >> encoding.condition_shift) & encoding.nibble),
    };
    if (found.condition >= encoding.first_unconditional) return null;
    if (found.destination == encoding.stack_register) return null;
    if (found.destination == encoding.zero_register) return null;
    if (found.then_source == encoding.stack_register) return null;
    if (found.else_source == encoding.stack_register) return null;
    return found;
}

/// Whether the condition holds for these flags. The codes are the ordinary
/// Armv7-M table; only the encoding around them is new.
pub fn passes(condition: u4, apsr: u32) bool {
    const n = apsr & flag.negative != 0;
    const z = apsr & flag.zero != 0;
    const c = apsr & flag.carry != 0;
    const v = apsr & flag.overflow != 0;
    return switch (condition >> 1) {
        0b000 => if (condition & 1 == 0) z else !z,
        0b001 => if (condition & 1 == 0) c else !c,
        0b010 => if (condition & 1 == 0) n else !n,
        0b011 => if (condition & 1 == 0) v else !v,
        0b100 => if (condition & 1 == 0) c and !z else !(c and !z),
        0b101 => if (condition & 1 == 0) n == v else n != v,
        0b110 => if (condition & 1 == 0) !z and n == v else !(!z and n == v),
        else => true,
    };
}

/// What lands in the destination, given both source values already read.
pub fn select(instruction: Instruction, apsr: u32, then_value: u32, else_value: u32) u32 {
    if (passes(instruction.condition, apsr)) return then_value;
    return switch (instruction.kind) {
        .sel => else_value,
        .inc => else_value +% 1,
        .inv => ~else_value,
        .neg => 0 -% else_value,
    };
}

/// How often the run needed this. Reported at the end so a run that leans on
/// the hook says so, instead of the CPU model's gap passing unnoticed.
pub const Selects = struct {
    stepped: usize = 0,

    pub fn quiet(self: Selects) bool {
        return self.stepped == 0;
    }
};
