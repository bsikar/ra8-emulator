//! AAPCS32 ABI conventions, call-site captures, and function signature summary (RA8EMU-1354).
const cfg_mod = @import("cfg.zig");
const value = @import("value.zig");

/// Register bitmasks following ARM Procedure Call Standard (AAPCS32).
pub const arg_mask: u16 = 0x000F; // r0..r3
pub const caller_saved_mask: u16 = 0x500F; // r0..r3, r12, lr
pub const callee_saved_mask: u16 = 0x2FF0; // r4..r11, sp

/// Inferred return convention across reached `.ret` exits of a function.
pub const ReturnKind = enum {
    none,
    r0,
    r0_r1_pair,
};

/// Observed argument values at a static direct, indirect, or tail call site.
pub const CallSite = struct {
    insn_idx: u32,
    address: u32,
    kind: cfg_mod.EdgeKind,
    target_address: ?u32 = null,
    target_name: ?[]const u8 = null,
    args: [4]value.Value,
};

/// Per-function AAPCS32 register summary.
pub const SignatureSummary = struct {
    /// Bit `i` (0..3) set when entry `r[i]` has at least one def-use consumer.
    used_args_mask: u4 = 0,
    /// Callee-saved GPRs (`r4..r11`, plus `lr` if stacked) saved by pushes.
    saved_callee_mask: u16 = 0,
    return_kind: ReturnKind = .none,
};

/// Apply AAPCS32 caller-saved clobbers after `bl` / `blx` returns:
/// `r0` receives `.call_result(call_addr)`, `r1..r3, r12, lr` become `.unknown`,
/// and NZCV flags become `.unknown`.
pub fn clobberCall(regs: *[16]value.Value, flags: *value.FlagState, call_addr: u32) void {
    regs[0] = .{ .call_result = call_addr };
    regs[1] = .unknown;
    regs[2] = .unknown;
    regs[3] = .unknown;
    regs[12] = .unknown;
    regs[14] = .unknown;
    flags.* = .unknown;
}

/// Snapshot `r0..r3` at a call instruction.
pub fn captureArgs(regs: *const [16]value.Value) [4]value.Value {
    return .{ regs[0], regs[1], regs[2], regs[3] };
}

/// Decide return kind given `r0`/`r1` values and whether `r0` was defined inside the function.
pub fn inferReturnKind(r0_defined_on_ret: bool, r0_val: value.Value, r1_val: value.Value) ReturnKind {
    if (!r0_defined_on_ret) return .none;
    if (r0_val == .pair_lo and r1_val == .pair_hi) {
        if (r0_val.pair_lo.eql(r1_val.pair_hi)) return .r0_r1_pair;
    }
    return .r0;
}
