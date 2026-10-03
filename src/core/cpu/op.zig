//! What an instruction group gives the decoder: a name for its class and a
//! function that turns an encoding it recognises into the code that runs it.
//!
//! The name is the class a lockstep divergence table reports under, so keep
//! it short and stable.
const Cpu = @import("cpu.zig").Cpu;
const Instr = @import("instr.zig").Instr;
const bus = @import("bus.zig");
const alignment = @import("alignment.zig");
const profile = @import("profile.zig");

/// An encoding that decodes but must not run: UDF, taken as UNDEFINSTR.
pub const Undefined = error{Undefined};

/// BKPT: a debug event the core takes once the instruction has decoded.
pub const Debug = error{Breakpoint};

pub const Error = bus.Error || alignment.Error || Undefined || Debug || error{ StackOverflow, InvalidState };

/// Runs one decoded instruction. The PC already points past it when this is
/// called; a branch writes the PC, everything else leaves it alone.
pub const Exec = *const fn (cpu: *Cpu, instr: Instr) Error!void;

pub const Group = struct {
    name: []const u8,
    decode: *const fn (instr: Instr) ?Exec,
    /// False for a group Unicorn cannot check: the Armv8.1-M encodings it does
    /// not implement. A lockstep run steps only the Zig core for these and
    /// counts them as skipped.
    oracle: bool = true,
    /// The core feature the group's encodings belong to: a core whose
    /// profile lacks it does not ask the group (RA8EMU-233).
    needs: profile.Feature = .base,
};
