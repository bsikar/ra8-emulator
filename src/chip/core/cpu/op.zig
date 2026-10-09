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

pub const Error = bus.Error || alignment.Error || Undefined || Debug || error{ StackOverflow, InvalidState, InvalidEntry, NoCoprocessor, LazyStateError, LazyPreserveError, LazyMemManage, LazyBusFault };

/// Runs one decoded instruction. The PC already points past it when this is
/// called; a branch writes the PC, everything else leaves it alone.
pub const Exec = *const fn (cpu: *Cpu, instr: Instr) Error!void;

/// How an instruction treats a nonzero EPSR.ECI/ICI (RA8EMU-453). The
/// default refuses it: the instruction takes INVSTATE before it runs.
pub const Eci = enum {
    refuses,
    /// A beat-wise MVE instruction: it reads ECI and moves it on itself.
    beat_wise,
    /// A load/store multiple: it restarts from the start with ICI cleared.
    restarts,
    /// LE, LETP and BKPT: ECI is left for the next instruction.
    keeps,
};

pub const Group = struct {
    name: []const u8,
    decode: *const fn (instr: Instr) ?Exec,
    /// False for a group with no lockstep oracle: the Armv8.1-M encodings.
    /// A lockstep run counts them as skipped.
    oracle: bool = true,
    /// The core feature the group's encodings belong to: a core whose
    /// profile lacks it does not ask the group (RA8EMU-233).
    needs: profile.Feature = .base,
    /// How the group's encodings treat a nonzero ECI.
    eci: Eci = .refuses,
    /// For a group whose encodings differ: decides per encoding.
    eci_of: ?*const fn (instr: Instr) Eci = null,

    pub fn eciOf(self: Group, instr: Instr) Eci {
        return if (self.eci_of) |of| of(instr) else self.eci;
    }
};
