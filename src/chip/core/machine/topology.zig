//! Which cores a machine carries, slot by slot (RA8EMU-1342).
//!
//! Slot 0 is the primary core: it always exists, comes out of reset first
//! and is the one a run starts on. Slot 1 is optional. A machine without a
//! second core has none: asking for one is refused with `error.AbsentCore`,
//! never answered with an idle placeholder.
const Core = @import("core.zig").Core;

pub const Slot = enum(u1) { cpu0, cpu1 };

pub const Error = error{AbsentCore};

pub const Topology = struct {
    primary: Core,
    second: ?Core = null,

    /// The core in `slot`, or null when the machine has none there.
    pub fn at(self: Topology, slot: Slot) ?Core {
        return switch (slot) {
            .cpu0 => self.primary,
            .cpu1 => self.second,
        };
    }

    /// The core in `slot`, refused when the machine has none there.
    pub fn require(self: Topology, slot: Slot) Error!Core {
        return self.at(slot) orelse Error.AbsentCore;
    }

    pub fn has(self: Topology, slot: Slot) bool {
        return self.at(slot) != null;
    }

    pub fn count(self: Topology) u2 {
        return if (self.second != null) 2 else 1;
    }
};
