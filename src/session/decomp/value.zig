//! Abstract value, 64-bit register pair, and flag-condition lattice (RA8EMU-1354).
//!
//! Monotonic flat/shallow lattice designed for AAPCS32 def-use dataflow without SSA:
//!   unvisited (bottom) < constant / sp_offset / entry_reg / pair / call_result < unknown (top).
const std = @import("std");

/// Origin of a 64-bit value held across two 32-bit registers (`lo_reg`, `hi_reg`).
pub const PairKind = enum {
    ldrd,
    long_mul,
    call_ret64,
};

/// Paired 64-bit register relationship defined at `def_address`.
pub const RegPair = struct {
    lo_reg: u4,
    hi_reg: u4,
    def_address: u32,
    kind: PairKind,
    const_u64: ?u64 = null,

    pub fn eql(a: RegPair, b: RegPair) bool {
        return a.lo_reg == b.lo_reg and
            a.hi_reg == b.hi_reg and
            a.def_address == b.def_address and
            a.kind == b.kind and
            a.const_u64 == b.const_u64;
    }
};

/// Abstract dataflow value carried by a single 32-bit GPR at a program point.
pub const Value = union(enum) {
    unvisited,
    unknown,
    entry_reg: u4,
    constant: u32,
    sp_offset: i32,
    pair_lo: RegPair,
    pair_hi: RegPair,
    call_result: u32,

    pub fn eql(a: Value, b: Value) bool {
        const Tag = std.meta.Tag(Value);
        const ta: Tag = a;
        const tb: Tag = b;
        if (ta != tb) return false;
        return switch (a) {
            .unvisited, .unknown => true,
            .entry_reg => |r| r == b.entry_reg,
            .constant => |c| c == b.constant,
            .sp_offset => |off| off == b.sp_offset,
            .pair_lo => |p| p.eql(b.pair_lo),
            .pair_hi => |p| p.eql(b.pair_hi),
            .call_result => |addr| addr == b.call_result,
        };
    }

    pub fn asConstant(self: Value) ?u32 {
        return switch (self) {
            .constant => |c| c,
            else => null,
        };
    }
};

/// Kind of flag-producing operation that defined NZCV.
pub const FlagKind = enum {
    cmp,
    cmn,
    tst,
    teq,
    result_flags,
};

/// Origin of the active NZCV flags along with operands sampled at the setter.
pub const FlagOrigin = struct {
    setter_insn: u32,
    setter_addr: u32,
    kind: FlagKind,
    lhs_reg: ?u4 = null,
    rhs_reg: ?u4 = null,
    rhs_imm: ?u32 = null,
    lhs_val: Value = .unknown,
    rhs_val: Value = .unknown,

    pub fn sameSite(a: FlagOrigin, b: FlagOrigin) bool {
        return a.setter_insn == b.setter_insn and
            a.setter_addr == b.setter_addr and
            a.kind == b.kind and
            a.lhs_reg == b.lhs_reg and
            a.rhs_reg == b.rhs_reg and
            a.rhs_imm == b.rhs_imm;
    }

    pub fn eql(a: FlagOrigin, b: FlagOrigin) bool {
        return a.sameSite(b) and a.lhs_val.eql(b.lhs_val) and a.rhs_val.eql(b.rhs_val);
    }
};

/// Monotonic lattice state for APSR.NZCV flags.
pub const FlagState = union(enum) {
    unvisited,
    unknown,
    known: FlagOrigin,

    pub fn eql(a: FlagState, b: FlagState) bool {
        const Tag = std.meta.Tag(FlagState);
        const ta: Tag = a;
        const tb: Tag = b;
        if (ta != tb) return false;
        return switch (a) {
            .unvisited, .unknown => true,
            .known => |ka| ka.eql(b.known),
        };
    }
};

/// Paired conditional instruction (branch, `csel`, `cbz`/`cbnz`, or IT slot) linked to its setter.
pub const ConditionPair = struct {
    consumer_insn: u32,
    consumer_addr: u32,
    cond: u4,
    origin: ?FlagOrigin = null,
    self_reg: ?u4 = null,
};

/// Join two register values monotonically in the flat lattice.
pub fn joinValue(a: Value, b: Value) Value {
    if (a == .unvisited) return b;
    if (b == .unvisited) return a;
    if (a.eql(b)) return a;
    return .unknown;
}

/// Join two flag states monotonically while preserving identical setter sites across joins.
pub fn joinFlags(a: FlagState, b: FlagState) FlagState {
    if (a == .unvisited) return b;
    if (b == .unvisited) return a;
    if (a == .unknown or b == .unknown) return .unknown;
    const ka = a.known;
    const kb = b.known;
    if (!ka.sameSite(kb)) return .unknown;
    return .{ .known = .{
        .setter_insn = ka.setter_insn,
        .setter_addr = ka.setter_addr,
        .kind = ka.kind,
        .lhs_reg = ka.lhs_reg,
        .rhs_reg = ka.rhs_reg,
        .rhs_imm = ka.rhs_imm,
        .lhs_val = joinValue(ka.lhs_val, kb.lhs_val),
        .rhs_val = joinValue(ka.rhs_val, kb.rhs_val),
    } };
}

/// Add a signed byte offset to `base` for `constant` and `sp_offset` values.
pub fn evalAdd(base: Value, delta: i32) Value {
    return switch (base) {
        .constant => |c| .{ .constant = c +% @as(u32, @bitCast(delta)) },
        .sp_offset => |off| if (std.math.add(i32, off, delta)) |sum| .{ .sp_offset = sum } else |_| .unknown,
        else => .unknown,
    };
}
