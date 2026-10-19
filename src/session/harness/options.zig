//! The harness's open options: what an image runs with. Split out of
//! the harness file so the file stays small; harness.zig re-exports it.
const std = @import("std");
const part = @import("ra8_chip").core.part;
const glcdc_vsync = @import("ra8_chip").periph.glcdc.vsync;
const history_recorder = @import("../history/recorder.zig");

pub const Options = struct {
    elf_path: []const u8,
    device: part.Part = .ra8p1,
    input_script: ?[]const u8 = null,
    /// The persistent history's host side (RA8EMU-1196), as the application
    /// fills it: the log segment's storage and the checkpoint objects' space,
    /// both over the application's history root. Both set arm the closed-round
    /// checkpoints; either missing records nothing.
    history_storage: ?history_recorder.Storage = null,
    history_objects: ?history_recorder.Objects = null,
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
    /// The host directory the run's file reads and writes open against
    /// (RA8EMU-968); null falls back to the process cwd for host tests.
    root: ?std.Io.Dir = null,
    /// The directory host file access resolves through, never `cwd()` directly.
    pub fn host(self: Options) std.Io.Dir {
        return self.root orelse std.Io.Dir.cwd();
    }
};
