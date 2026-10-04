//! Everything one run accumulates, in one place.
//!
//! These are the counters and tables the hooks write into as the run goes,
//! kept together so `main` wires them once and the report reads them once.
//! Lifted out of src/main.zig when the file passed the gate's 400 lines:
//! holding the run's state is its own purpose, and it grows by a field
//! every time a slice adds a counter.
const engine = @import("../../core/engine.zig");
const csel = @import("../../core/csel.zig");
const tz = @import("../../core/tz.zig");
const idle = @import("../../core/idle.zig");
const unmask = @import("../../core/unmask.zig");
const hotspots = @import("../../debug/hotspots.zig");
const functions = @import("../../debug/functions.zig");
const profile = functions.profile;
const profile_hook = @import("../../debug/profile_hook.zig");
const elf = @import("../../core/elf.zig");
const tally = @import("../../debug/tally.zig");
const pend_break = @import("../../core/pend_break.zig");
const pend_pace = @import("../../core/pend_pace.zig");
const mask_pace = @import("../../core/mask_pace.zig");
const pc_hits = @import("../../debug/pc_hits.zig");
const clocks = @import("../../periph/clocks.zig");
const lob = @import("../../core/lob.zig");
const divide_hook = @import("../../core/divide_hook.zig");
const nvic = @import("../../periph/nvic.zig");
const reboot_mod = @import("../../core/reboot.zig");
const undefined_ops = @import("../../core/undefined_ops.zig");
const report_run = @import("report/run.zig");
const bus_fault = @import("../../periph/bus_fault.zig");
const console_output = @import("console_output.zig");

pub const Parts = struct {
    watch: engine.Watch = .{},
    /// Where finished console lines go: `--console` and `--until`.
    tap: console_output.Tap = .{},
    loops: lob.Loops = .{},
    selects: csel.Selects = .{},
    clears: csel.clrm.Clears = .{},
    worlds: tz.Worlds = .{},
    idle: idle.Seam = .{},
    release: unmask.Release = .{},
    pcs: hotspots.Table = .{},
    fns: ?functions.Table = null,
    profile: ?profile.Table = null,
    taken: tally.Tally = .{},
    timebase: clocks.Clocks = .{},
    pend: pend_break.Pend = .{},
    pacing: pend_pace.Pace = .{},
    mask_pacing: mask_pace.Pace = .{},
    hits: pc_hits.Hits = .{},
    /// The BusFaults a `--bus-errors` run raised; src/core/bus_error.zig.
    bus_tally: bus_fault.Tally = .{},
    /// The CCR.DIV_0_TRP trap a Unicorn run hooks; src/core/divide_hook.zig.
    divide: divide_hook.Trap = undefined,

    /// Build the profile table. `hook` attaches the Unicorn code hook; leave
    /// it off for Zig and lockstep runs, which feed the table from the Zig
    /// core's retire path, or lockstep would count each instruction twice.
    pub fn attachProfile(self: *Parts, core: engine.Engine, image: elf.Image, hook: bool) !void {
        self.prepareProfile(image);
        if (!hook) return;
        profile_hook.attach(core.handle, &self.profile.?) catch return engine.Error.AttachFailed;
    }

    /// The profile table alone, for a run with no engine to hook (RA8EMU-592).
    pub fn prepareProfile(self: *Parts, image: elf.Image) void {
        self.profile = .{ .image = image };
        self.profile.?.prepare();
    }
};

/// What the run counted, gathered off the parts for the report.
///
/// Its own function so `main` stays inside the gate's 80 lines: this is a
/// transcription, not a decision, and it grows every time a slice adds a
/// counter.
pub fn tallyOf(
    parts: Parts,
    interrupts: nvic.Nvic,
    reboot: reboot_mod.Reboot,
    undefined_found: undefined_ops.Found,
) report_run.Tally {
    return .{
        .timebase = parts.timebase,
        .idle = parts.idle,
        .release = parts.release,
        .pend = parts.pend,
        .pacing = parts.pacing,
        .mask_pacing = parts.mask_pacing,
        .interrupts = interrupts,
        .reboot = reboot,
        .loops = parts.loops,
        .selects = parts.selects,
        .worlds = parts.worlds,
        .undefined_found = undefined_found,
        .bus_errors = parts.bus_tally,
        .pcs = parts.pcs,
        .fns = parts.fns,
        .profile = parts.profile,
        .hits = parts.hits,
        .taken = parts.taken,
    };
}
