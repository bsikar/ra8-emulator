//! EXC_RETURN: the value exception entry leaves in LR, and the one a handler
//! branches to when it returns.
//!
//! Bits 31:24 all set is what marks a branch target as an exception return.
//! Below that, bits 6:0 say which stack the frame is on and what it holds.
//! The core makes the default-stacking forms in the state the exception was
//! taken in: S and ES both set in Secure, both clear in Non-secure. A return
//! that crosses states needs the callee frame and its integrity signature
//! (RA8EMU-168), so `decode` turns S != ES away.

/// Bits 31:7, always set in a valid EXC_RETURN.
pub const res1: u32 = 0xFFFF_FF80;

pub const bits = struct {
    /// The exception was taken to the Secure state.
    pub const es: u32 = 1 << 0;
    /// The frame is on the Process stack (Thread mode only).
    pub const spsel: u32 = 1 << 2;
    /// Return to Thread mode; clear returns to Handler mode.
    pub const mode: u32 = 1 << 3;
    /// Set for a basic frame, clear when an FP context was stacked too.
    pub const ftype: u32 = 1 << 4;
    /// Default callee-register stacking rules.
    pub const dcrs: u32 = 1 << 5;
    /// The frame is on a Secure stack.
    pub const s: u32 = 1 << 6;
    /// Bit 1 is reserved and must be clear.
    pub const reserved: u32 = 1 << 1;
};

/// The bits every value `forEntry` makes carries; S and ES are set on top
/// in Secure, and FType unless an FP context was stacked.
const fixed: u32 = res1 | bits.dcrs;

/// S and ES together: the frame's stack and the exception's state.
const state: u32 = bits.s | bits.es;

/// Where an exception return goes.
pub const Target = struct {
    thread: bool,
    psp: bool,
    /// The frame is the extended one, with S0-S15 and FPSCR (FType clear).
    fp: bool = false,
    /// Taken to, and stacked in, the Secure state.
    secure: bool = true,
};

/// Whether a value written to the PC in Handler mode is an exception return.
pub fn marks(value: u32) bool {
    return value >> 24 == 0xFF;
}

/// LR on entry, from the mode and stack the processor was on when the
/// exception was taken.
pub fn forEntry(from: Target) u32 {
    var value = fixed;
    if (from.thread) value |= bits.mode;
    if (from.psp) value |= bits.spsel;
    if (!from.fp) value |= bits.ftype;
    if (from.secure) value |= state;
    return value;
}

/// The return a value asks for, or null for one the core cannot honour.
/// Handler mode on the Process stack is never valid.
pub fn decode(value: u32) ?Target {
    if (value & fixed != fixed) return null;
    if (value & bits.reserved != 0) return null;
    const both = value & state;
    if (both != 0 and both != state) return null;
    const target: Target = .{
        .thread = value & bits.mode != 0,
        .psp = value & bits.spsel != 0,
        .fp = value & bits.ftype == 0,
        .secure = both == state,
    };
    if (!target.thread and target.psp) return null;
    return target;
}
