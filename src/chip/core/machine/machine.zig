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
pub const generic = @import("generic.zig");
pub const memory = @import("memory.zig");
pub const topology = @import("topology.zig");

const Part = @import("../part/part.zig").Part;

pub const Core = core.Core;
pub const MemoryMap = memory.MemoryMap;
pub const Peripherals = enum { ra8, hx6538, none };
pub const Slot = topology.Slot;
pub const Topology = topology.Topology;

pub const Machine = struct {
    /// What `--part` selects it by; unique within the catalog.
    name: []const u8,
    /// Optional alternate `--part` / `--device` selector names.
    aliases: []const []const u8 = &.{},
    /// How a report prints it.
    label: []const u8,
    cores: Topology,
    /// Region ownership, aliases, permissions, MMIO routing, and optional
    /// vendor IDAU attribution (RA8EMU-1343).
    memory: *const MemoryMap = &memory.ra8,
    /// The on-chip peripheral composition beside the cores.
    part: Part,
    /// Explicit NPU capability override; null defers to `part.hasNpu()`.
    npu_enabled: ?bool = null,
    /// Explicit peripheral family override; null infers from `memory.attach_ra8_blocks`.
    peripherals: ?Peripherals = null,
    /// Primary and secondary rated core clocks in Hz.
    cpu0_hz: u32 = 1_000_000_000,
    cpu1_hz: u32 = 250_000_000,
    /// Hardware or architecture citation reported for custom memory maps.
    source: ?[]const u8 = null,

    pub fn primary(self: *const Machine) Core {
        return self.cores.primary;
    }

    pub fn core(self: *const Machine, slot: Slot) ?Core {
        return self.cores.at(slot);
    }

    pub fn hasSecond(self: *const Machine) bool {
        return self.cores.has(.cpu1);
    }

    /// Whether the composition has an active emulated Ethos-U55 NPU.
    pub fn hasNpu(self: *const Machine) bool {
        return self.npu_enabled orelse self.part.hasNpu();
    }

    pub fn peripheralsKind(self: *const Machine) Peripherals {
        return self.peripherals orelse if (self.memory.attach_ra8_blocks) .ra8 else .none;
    }
};
