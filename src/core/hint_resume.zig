//! WFE and YIELD on the Unicorn backend (RA8EMU-36).
//!
//! Unicorn ends a run on either hint as if it were an invalid instruction,
//! with the program counter already past it. Left alone, that halts any
//! image that waits for an event: a CPU1 parked in WFE until CPU0 runs SEV,
//! or a ThreadX port that yields. Measured on this engine: WFE and YIELD
//! both stop with UC_ERR_INSN_INVALID at the next instruction, while SEV
//! and NOP run straight through.
//!
//! So a stop like that whose previous halfword is one of the two hints is
//! taken as the hint having completed, and the run resumes. That is what
//! the Zig core does today (RA8EMU-18 completes them at once), so both
//! backends agree. Parking a core until an event arrives is the next step,
//! on src/core/core_event.zig.
//!
//! A GENUINELY UNDEFINED INSTRUCTION RIGHT AFTER A HINT stops at the same
//! address with the same error, and resuming would loop. So the instruction
//! after the hint is stepped once before handing back: if that stops at the
//! same place on an invalid instruction, the stop is the instruction's own
//! and is reported. The step and the hint are charged as one instruction.
const std = @import("std");
const fault = @import("fault.zig");
const Session = @import("session.zig").Session;

pub const wfe: u16 = 0xBF20;
pub const yield: u16 = 0xBF10;
const invalid = "UC_ERR_INSN_INVALID";

/// The hint in the halfword before `pc`, when there is one.
pub fn before(core: anytype, pc: u32) ?u16 {
    if (pc < 2) return null;
    const at = pc - 2;
    const word = core.readWord(at & ~@as(u32, 3)) catch return null;
    const half: u16 = @truncate(word >> @intCast((at & 2) * 8));
    return if (half == wfe or half == yield) half else null;
}

/// The hint a stop was, or null when it was something else.
pub fn stoppedOn(core: anytype, taken: fault.Fault) ?u16 {
    if (taken.access != null) return null;
    if (std.mem.indexOf(u8, taken.detail, invalid) == null) return null;
    return before(core, taken.pc);
}

/// Where to resume a stop that was a hint, or null to leave the stop. A
/// session that parks on WFE gets its WFE stops left: see `park_on_wfe`.
pub fn raised(core: anytype, session: Session, taken: fault.Fault) !?u32 {
    const hint = stoppedOn(core, taken) orelse return null;
    if (hint == wfe and session.park_on_wfe) return null;
    const stepped = try core.runChunk(taken.pc, 1, session.watch);
    const next = stepped orelse return try core.register(.pc);
    if (next.pc == taken.pc and std.mem.indexOf(u8, next.detail, invalid) != null) return null;
    // The instruction after the hint stopped for its own reason (an SVC,
    // a refused access, another hint). Hand it back to the loop to run
    // again, which sees that stop and routes it.
    return taken.pc;
}
