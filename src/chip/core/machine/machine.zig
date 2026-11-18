//! A machine description (RA8EMU-1342): the cores a run models and the
//! on-chip composition they sit on, picked by name on the command line.
//!
//! The session, the harness, the run loop, the CPUID window and the reports
//! read the core set from here, so nothing assumes that slot 0 is a
//! Cortex-M85 or that a second core exists. The RA8D2 and the RA8P1 are two
//! instances (catalog.zig). A new part adds its own instance beside them:
//! its cores through core.zig's builders and its topology, and the RA8
//! composition its blocks follow.
pub const catalog = @import("catalog.zig");
pub const core = @import("core.zig");
pub const topology = @import("topology.zig");

const Part = @import("../part/part.zig").Part;

pub const Core = core.Core;
pub const Slot = topology.Slot;
pub const Topology = topology.Topology;

pub const Machine = struct {
    /// What `--part` selects it by; unique within the catalog.
    name: []const u8,
    /// How a report prints it.
    label: []const u8,
    cores: Topology,
    /// The on-chip register and memory map the board composes beside the
    /// cores. Until the map comes from the description itself (RA8EMU-1343),
    /// every machine sits on one of the RA8 compositions.
    part: Part,

    pub fn primary(self: *const Machine) Core {
        return self.cores.primary;
    }

    pub fn core(self: *const Machine, slot: Slot) ?Core {
        return self.cores.at(slot);
    }

    pub fn hasSecond(self: *const Machine) bool {
        return self.cores.has(.cpu1);
    }

    /// Whether the composition has the Ethos-U55 behind 0x4014_0000.
    pub fn hasNpu(self: *const Machine) bool {
        return self.part.hasNpu();
    }
};
