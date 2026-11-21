//! The harness's open options: what an image runs with. Split out of
//! the harness file so the file stays small; harness.zig re-exports it.
const file_ops = @import("../file_ops.zig");
const glcdc_vsync = @import("ra8_chip").periph.glcdc.vsync;
const history_recorder = @import("../history/recorder.zig");
const machine_mod = @import("ra8_chip").core.machine;
const part = @import("ra8_chip").core.part;

pub const Options = struct {
    elf_path: []const u8 = "",
    /// The image's bytes when the caller already read them: the harness
    /// copies these and does not read `elf_path`, so the run is of the
    /// bytes the caller looked at.
    elf_bytes: ?[]const u8 = null,
    device: part.Part = .ra8p1,
    /// Explicit machine description (RA8EMU-1342); null uses the catalog
    /// entry for `device`.
    machine: ?*const machine_mod.Machine = null,
    /// Wire SAU/IDAU security attribution on the harness core (enabled automatically for HX6538).
    attribution: bool = false,
    /// Deliver architectural BusFaults instead of stopping immediately on an unmapped access.
    bus_errors: bool = false,
    input_script: ?[]const u8 = null,
    /// Caller-supplied input script text; when set, `input_script` is not read
    /// through `files`.
    input_script_bytes: ?[]const u8 = null,
    /// The persistent history's host side (RA8EMU-1196), as the application
    /// fills it: the log segment's storage and the checkpoint objects' space,
    /// both over the application's history root. Both set arm the closed-round
    /// checkpoints; either missing records nothing.
    history_storage: ?history_recorder.Storage = null,
    history_objects: ?history_recorder.Objects = null,
    /// The disk budget the application fills (RA8EMU-1196): the share
    /// this history takes on the volume and a fresh free-space read per
    /// check. Null runs the history uncapped.
    history_disk: ?history_recorder.Budget = null,
    /// The bytes checkpoints may take on the volume (RA8EMU-1196): the
    /// application fills it from its share math, the projection thins
    /// the cadence past it. Zero runs the cadence unprojected.
    history_checkpoint_cap: u64 = 0,
    /// The board profile's text (RA8EMU-1152); null is the shipped EK-RA8D2
    /// default. Its labels point into the caller's text and outlive it.
    board_profile: ?[]const u8 = null,
    /// Where snapshots live (RA8EMU-1175); null keeps bare names in the working directory.
    state_dir: ?[]const u8 = null,
    /// How many stops the rewind history keeps (RA8EMU-1170); the oldest falls off past it.
    history_frames: u32 = 240,
    /// One checkpoint every N closed rounds (RA8EMU-1196); zero disables.
    checkpoint_every: u32 = 64,
    settle_window_ns: u64 = 50_000_000,
    /// Whether the boundary stretches across idle sleeps (RA8EMU-1120).
    idle_skip: bool = true,
    /// The run's `panel_vsync` config (RA8EMU R9), stored the way a plain run's fit stores it.
    panel_vsync: ?glcdc_vsync.Config = null,
    /// Host-backed file and state callbacks (ADR 0004 D20). Null keeps the
    /// harness purely in-memory (`elf_bytes` required, state files unavailable).
    files: ?file_ops.Ops = null,

    pub fn resolvedMachine(self: Options) *const machine_mod.Machine {
        return self.machine orelse machine_mod.catalog.ofPart(self.device);
    }
};
