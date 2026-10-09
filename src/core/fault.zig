//! Why a run stopped badly: the faulting access, and where the hook puts it.
//!
//! An invalid access is reported twice and never in one piece. The
//! memory hook fires first and carries the address, the width and the value,
//! but cannot stop the run or return anything; the run then ends with an
//! error code that carries none of those. So the hook writes what it saw
//! into a latch and the run loop reads it back afterwards, which is the only
//! reason `Watch` exists at all.
//!
//! Both sit here rather than in engine.zig because the C-convention hooks
//! need them and the engine needs the hooks: with the pair in their own file
//! that is a line, not a loop.
const std = @import("std");

pub const Fault = struct {
    pc: u32,
    detail: []const u8,
    /// The access that took the fault, when one was reported.
    access: ?Access = null,

    pub const Access = struct {
        kind: enum { read, write, fetch },
        address: u64,
        size: u8,
        value: u64,
    };
};

/// Catches the invalid access behind a fault. The address and
/// width in a hook and only the error code afterwards, so the hook writes here
/// and `run` reads it back once the run has stopped.
pub const Watch = struct {
    last: ?Fault.Access = null,

    pub fn clear(self: *Watch) void {
        self.last = null;
    }
};
