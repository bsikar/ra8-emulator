//! The R-Switch mode machine: the four modes an ETHA port or the GWCA agent
//! moves through, and the steps between them that exist.
//!
//! dev reads the mode status straight out of the mode command, so the machine
//! converges inside the store instruction and converges from anywhere: an
//! image that jumped RESET straight to OPERATION got an operational agent in
//! the emulator and a stuck one on the bench, because the silicon only takes
//! the step in front of it. The reachable table below is this model's reading
//! of that four-mode machine, and a step that is not on it is refused and
//! counted rather than quietly taken.
const std = @import("std");

pub const Mode = enum(u2) {
    reset = 0,
    disable = 1,
    config = 2,
    operation = 3,
};

/// Whether the machine can go straight from `from` to `to`. Reset is the way
/// out of anywhere; everything else is one rung at a time.
pub fn reachable(from: Mode, to: Mode) bool {
    if (from == to) return true;
    if (to == .reset) return true;
    return switch (from) {
        .reset => to == .disable,
        .disable => to == .config,
        .config => to == .operation or to == .disable,
        .operation => to == .config,
    };
}

/// One mode machine: what it was commanded, where it is, and the steps it
/// would not take.
pub const Machine = struct {
    mode: Mode = .reset,
    /// Mode commands the firmware wrote.
    commands: u32 = 0,
    /// Commands that moved the machine.
    changes: u32 = 0,
    /// Commands refused because the step does not exist.
    refused: u32 = 0,
    /// The mode the last refused command asked for.
    last_refused: ?Mode = null,

    pub fn command(self: *Machine, value: u32) void {
        self.commands += 1;
        const wanted: Mode = @enumFromInt(@as(u2, @truncate(value)));
        if (!reachable(self.mode, wanted)) {
            self.refused += 1;
            self.last_refused = wanted;
            return;
        }
        if (wanted != self.mode) self.changes += 1;
        self.mode = wanted;
    }

    /// What the status register reports: where the machine actually is, not
    /// what it was last asked for.
    pub fn status(self: *const Machine) u32 {
        return @intFromEnum(self.mode);
    }

    pub fn operational(self: *const Machine) bool {
        return self.mode == .operation;
    }

    pub fn quiet(self: *const Machine) bool {
        return self.commands == 0;
    }
};
